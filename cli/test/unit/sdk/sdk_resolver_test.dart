import 'dart:io';

import 'package:flutter_run/src/common/errors.dart';
import 'package:flutter_run/src/common/host_environment.dart';
import 'package:flutter_run/src/common/paths.dart';
import 'package:flutter_run/src/sdk/sdk_resolver.dart';
import 'package:flutter_run/src/sdk/sdk_steps.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fake_sdk.dart';

/// The executable names the resolver looks for on this OS.
final flutterBin = Platform.isWindows ? 'flutter.bat' : 'flutter';
final dartBin = Platform.isWindows ? 'dart.exe' : 'dart';

void main() {
  late Directory tmp;
  late String home;
  late String project;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rd_sdk_');
    home = p.join(tmp.resolveSymbolicLinksSync(), 'home')..toString();
    Directory(home).createSync();
    project = p.join(tmp.resolveSymbolicLinksSync(), 'work', 'app');
    Directory(project).createSync(recursive: true);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  String sdkAt(String name) =>
      makeFakeSdk(p.join(tmp.resolveSymbolicLinksSync(), 'sdks', name));

  HostEnvironment host([Map<String, String> env = const {}]) =>
      hostFor(project, env: {'HOME': home, 'USERPROFILE': home, ...env});

  Future<SdkResolution> resolve(
    HostEnvironment env, {
    String? explicit,
    bool strict = false,
    SdkKind kind = SdkKind.flutter,
    String? dir,
  }) => SdkResolver(env).resolve(
    projectDir: dir ?? project,
    explicitSdkPath: explicit,
    strictFvm: strict,
    kind: kind,
  );

  void writeFile(String path, String content) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  StepOutcome outcomeOf(SdkResolution r, String id) =>
      r.trace.firstWhere((s) => s.id == id).outcome;

  group('each step alone', () {
    test('1 explicit', () async {
      final sdk = sdkAt('explicit');
      final r = await resolve(host(), explicit: sdk);
      expect(r.flutter!.sourceStep, 'explicit');
      expect(r.flutter!.root, sdk);
      expect(r.flutter!.flutterExecutable, p.join(sdk, 'bin', flutterBin));
      expect(r.flutter!.bundledDartExecutable, isNotNull);
      expect(r.flutter!.flutterVersion, '3.99.0');
      expect(r.flutter!.dartVersion, '3.99.1');
    });

    test('2 env', () async {
      final sdk = sdkAt('env');
      final r = await resolve(host({'FLUTTER_RUN_FLUTTER_SDK': sdk}));
      expect(r.flutter!.sourceStep, 'env');
      expect(r.flutter!.root, sdk);
    });

    test('3 fvm-link in the project', () async {
      final sdk = sdkAt('fvm');
      Directory(p.join(project, '.fvm')).createSync();
      Link(p.join(project, '.fvm', 'flutter_sdk')).createSync(sdk);
      final r = await resolve(host());
      expect(r.flutter!.sourceStep, 'fvm-link');
      expect(r.flutter!.root, sdk);
    }, skip: Platform.isWindows ? 'needs symlink privileges' : null);

    test('3 fvm-link found from a subdirectory and an ancestor', () async {
      final sdk = sdkAt('fvm');
      final ancestor = p.dirname(project);
      Directory(p.join(ancestor, '.fvm')).createSync();
      Link(p.join(ancestor, '.fvm', 'flutter_sdk')).createSync(sdk);
      final sub = p.join(project, 'lib', 'src')..toString();
      Directory(sub).createSync(recursive: true);
      final r = await resolve(host(), dir: sub);
      expect(r.flutter!.sourceStep, 'fvm-link');
      expect(r.flutter!.root, sdk);
    }, skip: Platform.isWindows ? 'needs symlink privileges' : null);

    test('3 fvm-link with a relative target', () async {
      final sdk = sdkAt('fvm');
      Directory(p.join(project, '.fvm')).createSync();
      Link(
        p.join(project, '.fvm', 'flutter_sdk'),
      ).createSync(p.relative(sdk, from: p.join(project, '.fvm')));
      final r = await resolve(host());
      expect(r.flutter!.root, sdk);
    }, skip: Platform.isWindows ? 'needs symlink privileges' : null);

    test('3 broken fvm-link is invalid and resolution continues', () async {
      Directory(p.join(project, '.fvm')).createSync();
      Link(
        p.join(project, '.fvm', 'flutter_sdk'),
      ).createSync(p.join(tmp.path, 'missing'));
      final sdk = sdkAt('env');
      final r = await resolve(host({'FLUTTER_ROOT': sdk}));
      expect(outcomeOf(r, 'fvm-link'), StepOutcome.invalid);
      expect(r.flutter!.sourceStep, 'flutter-root');
    }, skip: Platform.isWindows ? 'needs symlink privileges' : null);

    test('4 .fvmrc + 5 FVM_CACHE_PATH', () async {
      final cache = p.join(tmp.path, 'cache');
      makeFakeSdk(p.join(cache, 'versions', '3.24.0'));
      writeFile(p.join(project, '.fvmrc'), '{"flutter": "3.24.0"}');
      final r = await resolve(host({'FVM_CACHE_PATH': cache}));
      expect(r.flutter!.sourceStep, 'fvm-cache');
      expect(r.flutter!.root, p.join(cache, 'versions', '3.24.0'));
      expect(outcomeOf(r, 'fvmrc'), StepOutcome.found);
    });

    test('4 .fvmrc from an ancestor with a channel name', () async {
      final cache = p.join(tmp.path, 'cache');
      makeFakeSdk(p.join(cache, 'versions', 'stable'));
      writeFile(p.join(p.dirname(project), '.fvmrc'), '{"flutter":"stable"}');
      final r = await resolve(host({'FVM_CACHE_PATH': cache}));
      expect(r.flutter!.root, p.join(cache, 'versions', 'stable'));
    });

    test('4b legacy fvm_config.json', () async {
      final cache = p.join(tmp.path, 'cache');
      makeFakeSdk(p.join(cache, 'versions', '2.10.5'));
      writeFile(
        p.join(project, '.fvm', 'fvm_config.json'),
        '{"flutterSdkVersion": "2.10.5", "flavors": {}}',
      );
      final r = await resolve(host({'FVM_CACHE_PATH': cache}));
      expect(r.flutter!.sourceStep, 'fvm-cache');
      expect(outcomeOf(r, 'fvm-legacy'), StepOutcome.found);
      expect(outcomeOf(r, 'fvmrc'), StepOutcome.notFound);
    });

    test('.fvmrc wins over the legacy file', () async {
      final cache = p.join(tmp.path, 'cache');
      makeFakeSdk(p.join(cache, 'versions', '3.0.0'));
      makeFakeSdk(p.join(cache, 'versions', '2.0.0'));
      writeFile(p.join(project, '.fvmrc'), '{"flutter":"3.0.0"}');
      writeFile(
        p.join(project, '.fvm', 'fvm_config.json'),
        '{"flutterSdkVersion":"2.0.0"}',
      );
      final r = await resolve(host({'FVM_CACHE_PATH': cache}));
      expect(r.flutter!.root, p.join(cache, 'versions', '3.0.0'));
      expect(outcomeOf(r, 'fvm-legacy'), StepOutcome.skipped);
    });

    test('5 FVM_HOME and the home folder default', () async {
      writeFile(p.join(project, '.fvmrc'), '{"flutter":"1.2.3"}');
      final viaHome = makeFakeSdk(p.join(home, 'fvm', 'versions', '1.2.3'));
      expect((await resolve(host())).flutter!.root, viaHome);

      final fvmHome = p.join(tmp.path, 'fvmhome');
      final viaFvmHome = makeFakeSdk(p.join(fvmHome, 'versions', '1.2.3'));
      expect(
        (await resolve(host({'FVM_HOME': fvmHome}))).flutter!.root,
        viaFvmHome,
      );
      final cache = p.join(tmp.path, 'cache');
      final viaCache = makeFakeSdk(p.join(cache, 'versions', '1.2.3'));
      expect(
        (await resolve(
          host({'FVM_HOME': fvmHome, 'FVM_CACHE_PATH': cache}),
        )).flutter!.root,
        viaCache,
        reason: 'FVM_CACHE_PATH has priority',
      );
    });

    test('5 version not installed -> notFound and listed', () async {
      writeFile(p.join(project, '.fvmrc'), '{"flutter":"9.9.9"}');
      final r = await resolve(host());
      expect(r.flutter, isNull);
      final step = r.trace.firstWhere((s) => s.id == 'fvm-cache');
      expect(step.outcome, StepOutcome.notFound);
      expect(step.detail, contains('9.9.9'));
    });

    test('a malicious version name is not used as a path', () async {
      writeFile(p.join(project, '.fvmrc'), '{"flutter":"../../evil"}');
      final r = await resolve(host());
      expect(outcomeOf(r, 'fvmrc'), StepOutcome.invalid);
      expect(outcomeOf(r, 'fvm-cache'), StepOutcome.skipped);
    });

    test('6 puro with PURO_ROOT', () async {
      final puroRoot = p.join(tmp.path, 'puro');
      final sdk = makeFakeSdk(p.join(puroRoot, 'envs', 'stable', 'flutter'));
      writeFile(p.join(project, '.puro.json'), '{"env": "stable"}');
      final r = await resolve(host({'PURO_ROOT': puroRoot}));
      expect(r.flutter!.sourceStep, 'puro');
      expect(r.flutter!.root, sdk);
    });

    test('6 puro default ~/.puro', () async {
      final sdk = makeFakeSdk(p.join(home, '.puro', 'envs', 'dev', 'flutter'));
      writeFile(p.join(p.dirname(project), '.puro.json'), '{"env":"dev"}');
      final r = await resolve(host());
      expect(r.flutter!.root, sdk);
    });

    test('7 FLUTTER_ROOT', () async {
      final sdk = sdkAt('root');
      final r = await resolve(host({'FLUTTER_ROOT': sdk}));
      expect(r.flutter!.sourceStep, 'flutter-root');
      expect(r.flutter!.root, sdk);
    });

    test('8 PATH', () async {
      final sdk = sdkAt('onpath');
      final r = await resolve(host({'PATH': p.join(sdk, 'bin')}));
      expect(r.flutter!.sourceStep, 'path');
      expect(r.flutter!.root, sdk);
      expect(r.flutter!.flutterExecutable, p.join(sdk, 'bin', flutterBin));
    });

    test('8 PATH symlink is resolved to the SDK root', () async {
      final sdk = sdkAt('real');
      final links = Directory(p.join(tmp.path, 'links'))..createSync();
      Link(
        p.join(links.path, 'flutter'),
      ).createSync(p.join(sdk, 'bin', 'flutter'));
      final r = await resolve(host({'PATH': links.path}));
      expect(r.flutter!.root, sdk);
      expect(r.flutter!.flutterExecutable, p.join(sdk, 'bin', 'flutter'));
      expect(r.flutter!.sourceStep, 'path');
    }, skip: Platform.isWindows ? 'needs symlink privileges' : null);

    test('8 PATH shim is used as found with a null root', () async {
      final shims = Directory(p.join(tmp.path, 'shims'))..createSync();
      final shim = File(p.join(shims.path, 'flutter'))
        ..writeAsStringSync('#!/bin/sh\nexec true\n');
      Process.runSync('chmod', ['+x', shim.path]);
      final r = await resolve(host({'PATH': shims.path}));
      expect(r.flutter!.root, isNull);
      expect(r.flutter!.flutterExecutable, shim.path);
      expect(r.flutter!.bundledDartExecutable, isNull);
      expect(r.flutter!.flutterVersion, isNull);
      expect(r.flutter!.sourceStep, 'path');
    }, skip: Platform.isWindows ? 'posix shim' : null);
  });

  group('precedence', () {
    test('explicit > env > fvm > puro > FLUTTER_ROOT > PATH', () async {
      final explicit = sdkAt('explicit');
      final envSdk = sdkAt('env');
      final fvm = sdkAt('fvm');
      final puroRoot = p.join(tmp.path, 'puro');
      makeFakeSdk(p.join(puroRoot, 'envs', 'e', 'flutter'));
      final rootSdk = sdkAt('root');
      final pathSdk = sdkAt('path');
      Directory(p.join(project, '.fvm')).createSync();
      final cache = p.join(tmp.path, 'cache');
      makeFakeSdk(p.join(cache, 'versions', '3.0.0'));
      writeFile(p.join(project, '.fvmrc'), '{"flutter":"3.0.0"}');
      writeFile(p.join(project, '.puro.json'), '{"env":"e"}');
      final linkSupported = !Platform.isWindows;
      if (linkSupported) {
        Link(p.join(project, '.fvm', 'flutter_sdk')).createSync(fvm);
      }
      final env = {
        'FLUTTER_RUN_FLUTTER_SDK': envSdk,
        'FVM_CACHE_PATH': cache,
        'PURO_ROOT': puroRoot,
        'FLUTTER_ROOT': rootSdk,
        'PATH': p.join(pathSdk, 'bin'),
      };
      Future<String> src({String? ex, Map<String, String>? e}) async =>
          (await resolve(host(e ?? env), explicit: ex)).flutter!.sourceStep;

      expect(await src(ex: explicit), 'explicit');
      expect(await src(), 'env');
      env.remove('FLUTTER_RUN_FLUTTER_SDK');
      expect(await src(), linkSupported ? 'fvm-link' : 'fvm-cache');
      if (linkSupported) {
        Link(p.join(project, '.fvm', 'flutter_sdk')).deleteSync();
        expect(await src(), 'fvm-cache');
      }
      File(p.join(project, '.fvmrc')).deleteSync();
      expect(await src(), 'puro');
      File(p.join(project, '.puro.json')).deleteSync();
      expect(await src(), 'flutter-root');
      env.remove('FLUTTER_ROOT');
      expect(await src(), 'path');
    });

    test('invalid env value is recorded and falls through', () async {
      final root = sdkAt('root');
      final r = await resolve(
        host({
          'FLUTTER_RUN_FLUTTER_SDK': p.join(tmp.path, 'nope'),
          'FLUTTER_ROOT': root,
        }),
      );
      expect(outcomeOf(r, 'env'), StepOutcome.invalid);
      expect(r.flutter!.sourceStep, 'flutter-root');
    });
  });

  group('failures', () {
    test('invalid explicit path is an error, not a fall-through', () async {
      final good = sdkAt('root');
      final env = host({'FLUTTER_ROOT': good});
      final bad = p.join(tmp.path, 'nope');
      final r = await resolve(env, explicit: bad);
      expect(r.flutter, isNull);
      expect(outcomeOf(r, 'explicit'), StepOutcome.invalid);
      await expectLater(
        SdkResolver(
          env,
        ).resolveOrThrow(projectDir: project, explicitSdkPath: bad),
        throwsA(
          isA<SdkNotFoundException>().having(
            (e) => e.message,
            'message',
            contains('configured'),
          ),
        ),
      );
    });

    test('strictFvm fails when fvm sources are missing', () async {
      final root = sdkAt('root');
      final env = host({'FLUTTER_ROOT': root, 'PATH': p.join(root, 'bin')});
      final r = await resolve(env, strict: true);
      expect(r.flutter, isNull);
      expect(outcomeOf(r, 'puro'), StepOutcome.skipped);
      expect(outcomeOf(r, 'flutter-root'), StepOutcome.skipped);
      expect(outcomeOf(r, 'path'), StepOutcome.skipped);
      await expectLater(
        SdkResolver(env).resolveOrThrow(projectDir: project, strictFvm: true),
        throwsA(
          isA<SdkNotFoundException>().having(
            (e) => e.message,
            'message',
            contains('fvm'),
          ),
        ),
      );
    });

    test('strictFvm succeeds with .fvmrc and an installed version', () async {
      final cache = p.join(tmp.path, 'cache');
      makeFakeSdk(p.join(cache, 'versions', '3.0.0'));
      writeFile(p.join(project, '.fvmrc'), '{"flutter":"3.0.0"}');
      final r = await resolve(host({'FVM_CACHE_PATH': cache}), strict: true);
      expect(r.flutter!.sourceStep, 'fvm-cache');
    });

    test('explicit still wins under strictFvm', () async {
      final sdk = sdkAt('explicit');
      final r = await resolve(host(), explicit: sdk, strict: true);
      expect(r.flutter!.sourceStep, 'explicit');
    });

    test('not found lists every step and all three fixes', () async {
      final env = host();
      final r = await resolve(env);
      expect(r.flutter, isNull);
      expect(
        r.trace.map((s) => s.id),
        containsAllInOrder([
          'explicit',
          'env',
          'fvm-link',
          'fvmrc',
          'fvm-legacy',
          'fvm-cache',
          'puro',
          'flutter-root',
          'path',
        ]),
      );
      try {
        await SdkResolver(env).resolveOrThrow(projectDir: project);
        fail('should throw');
      } on SdkNotFoundException catch (e) {
        expect(e.exitCode, ExitCodes.sdkNotFound);
        expect(e.tried, hasLength(r.trace.length));
        for (final step in r.trace) {
          expect(e.message, contains(step.description));
        }
        expect(e.hint, contains('flutterSdkPath'));
        expect(e.hint, contains('FLUTTER_RUN_FLUTTER_SDK'));
        expect(e.hint, contains('PATH'));
      }
    });
  });

  group('kind dart', () {
    test('uses the Flutter SDK bundled dart', () async {
      final sdk = sdkAt('root');
      final r = await resolve(host({'FLUTTER_ROOT': sdk}), kind: SdkKind.dart);
      expect(
        r.dartExecutable,
        p.join(
          sdk,
          'bin',
          'cache',
          'dart-sdk',
          'bin',
          Platform.isWindows ? 'dart.exe' : 'dart',
        ),
      );
      expect(r.flutter!.root, sdk);
    });

    test('falls back to DART_SDK when the Flutter SDK has no dart', () async {
      final sdk = makeFakeSdk(p.join(tmp.path, 'nodart'), withDart: false);
      final dartSdk = makeFakeSdk(p.join(tmp.path, 'dartsdk'));
      final dartHome = p.join(dartSdk, 'bin', 'cache', 'dart-sdk');
      final r = await resolve(
        host({'FLUTTER_ROOT': sdk, 'DART_SDK': dartHome}),
        kind: SdkKind.dart,
      );
      expect(r.dartExecutable, p.join(dartHome, 'bin', dartBin));
      expect(outcomeOf(r, 'bundled-dart'), StepOutcome.notFound);
    });

    test('falls back to dart on PATH without any Flutter SDK', () async {
      final dartSdk = makeFakeSdk(p.join(tmp.path, 'dartsdk'));
      final bin = p.join(dartSdk, 'bin', 'cache', 'dart-sdk', 'bin');
      final r = await resolve(host({'PATH': bin}), kind: SdkKind.dart);
      expect(r.flutter, isNull);
      expect(r.dartExecutable, p.join(bin, 'dart'));
      expect(outcomeOf(r, 'dart-path'), StepOutcome.found);
    }, skip: Platform.isWindows ? 'posix names' : null);

    test('explicit invalid Flutter path is non-fatal for dart', () async {
      final dartSdk = makeFakeSdk(p.join(tmp.path, 'dartsdk'));
      final bin = p.join(dartSdk, 'bin', 'cache', 'dart-sdk', 'bin');
      final r = await resolve(
        host({'PATH': bin}),
        kind: SdkKind.dart,
        explicit: p.join(tmp.path, 'nope'),
      );
      expect(r.dartExecutable, isNotNull);
      expect(outcomeOf(r, 'explicit'), StepOutcome.invalid);
    }, skip: Platform.isWindows ? 'posix names' : null);

    test('nothing found -> error listing the dart steps too', () async {
      final env = host();
      try {
        await SdkResolver(
          env,
        ).resolveOrThrow(projectDir: project, kind: SdkKind.dart);
        fail('should throw');
      } on SdkNotFoundException catch (e) {
        expect(e.message, contains('Dart'));
        expect(e.message, contains('DART_SDK'));
        expect(e.message, contains('dart on PATH'));
        expect(e.message, contains('flutter on PATH'));
      }
    });

    test('strictFvm does not fall back to PATH dart', () async {
      final dartSdk = makeFakeSdk(p.join(tmp.path, 'dartsdk'));
      final bin = p.join(dartSdk, 'bin', 'cache', 'dart-sdk', 'bin');
      final r = await resolve(
        host({'PATH': bin}),
        kind: SdkKind.dart,
        strict: true,
      );
      expect(r.dartExecutable, isNull);
    }, skip: Platform.isWindows ? 'posix names' : null);
  });

  test('dot-names in .fvmrc are rejected', () async {
    writeFile(p.join(project, '.fvmrc'), '{"flutter":".."}');
    final r = await resolve(host());
    expect(outcomeOf(r, 'fvmrc'), StepOutcome.invalid);
  });

  test('relative explicit path is relative to the project', () async {
    final sdk = sdkAt('rel');
    final rel = p.relative(sdk, from: project);
    final r = await resolve(host(), explicit: rel);
    expect(r.flutter!.root, sdk);
  });

  test(
    'PATH wrapper in a bin folder without SDK markers is a launcher',
    () async {
      final bin = Directory(p.join(tmp.path, 'usr', 'bin'))
        ..createSync(recursive: true);
      final f = File(p.join(bin.path, 'flutter'))
        ..writeAsStringSync('#!/bin/sh\n');
      Process.runSync('chmod', ['+x', f.path]);
      final r = await resolve(host({'PATH': bin.path}));
      expect(r.flutter!.root, isNull);
      expect(r.flutter!.flutterExecutable, f.path);
    },
    skip: Platform.isWindows ? 'posix' : null,
  );

  test('describeTrace numbers every step', () async {
    final r = await resolve(host());
    final lines = r.describeTrace().split('\n');
    expect(lines, hasLength(r.trace.length));
    expect(lines.first, startsWith('1. '));
  });

  test('canonical comparison helper still agrees with root', () async {
    final sdk = sdkAt('root');
    final r = await resolve(host({'FLUTTER_ROOT': sdk}));
    expect(pathsEqual(r.flutter!.root!, sdk, host()), isTrue);
  });

  group('real SDK', () {
    final env = HostEnvironment.system();
    final onPath = findExecutableOnPath('flutter', env);
    test('resolves the flutter found on PATH', () async {
      final r = await SdkResolver(
        env,
      ).resolveOrThrow(projectDir: Directory.systemTemp.path);
      final sdk = r.flutter!;
      final real = File(onPath!).resolveSymbolicLinksSync();
      expect(sdk.sourceStep, anyOf('path', 'flutter-root', 'env'));
      if (sdk.root != null && sdk.sourceStep == 'path') {
        expect(sdk.root, p.dirname(p.dirname(real)));
        expect(File(sdk.flutterExecutable).existsSync(), isTrue);
        expect(sdk.flutterVersion, matches(RegExp(r'^\d+\.\d+')));
        expect(sdk.dartVersion, matches(RegExp(r'^\d+\.\d+')));
        expect(File(sdk.bundledDartExecutable!).existsSync(), isTrue);
      }
      final dart = await SdkResolver(env).resolveOrThrow(
        projectDir: Directory.systemTemp.path,
        kind: SdkKind.dart,
      );
      expect(File(dart.dartExecutable!).existsSync(), isTrue);
    }, skip: onPath == null ? 'flutter is not on PATH' : null);
  });
}
