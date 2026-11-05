import 'dart:convert';

import 'package:flutter_run/src/common/host_environment.dart';
import 'package:flutter_run/src/sdk/sdk_resolver.dart';
import 'package:flutter_run/src/sdk/sdk_steps.dart';
import 'package:test/test.dart';

/// In-memory Windows-style file system (keys are exact path strings).
class MemFs implements SdkFileSystem {
  final Set<String> files = {};
  final Set<String> dirs = {};
  final Map<String, String> links = {};
  final Map<String, String> text = {};

  void addSdk(String root) {
    files
      ..add('$root\\bin\\flutter.bat')
      ..add('$root\\bin\\internal\\engine.version')
      ..add('$root\\bin\\cache\\dart-sdk\\bin\\dart.exe');
  }

  @override
  bool isFile(String path) => files.contains(path);
  @override
  bool isDirectory(String path) => dirs.contains(path);
  @override
  bool exists(String path) =>
      files.contains(path) || dirs.contains(path) || links.containsKey(path);
  @override
  bool isExecutableFile(String path) => files.contains(path);
  @override
  String? resolveLink(String path) =>
      links[path] ?? (exists(path) ? path : null);
  @override
  String? readText(String path) => text[path];
}

HostEnvironment win(Map<String, String> env, {String cwd = r'C:\proj\app'}) =>
    HostEnvironment(
      os: HostOs.windows,
      environment: {'USERPROFILE': r'C:\Users\Me', ...env},
      currentDirectory: cwd,
    );

void main() {
  late MemFs fs;
  setUp(() => fs = MemFs());

  Future<SdkResolution> resolve(
    HostEnvironment env, {
    SdkKind kind = SdkKind.flutter,
    String dir = r'C:\proj\app',
  }) => SdkResolver(env, fileSystem: fs).resolve(projectDir: dir, kind: kind);

  test('explicit root selects flutter.bat', () async {
    fs.addSdk(r'C:\src\flutter');
    final r = await SdkResolver(
      win({}),
      fileSystem: fs,
    ).resolve(projectDir: r'C:\proj\app', explicitSdkPath: r'C:\src\flutter');
    expect(r.flutter!.flutterExecutable, r'C:\src\flutter\bin\flutter.bat');
    expect(
      r.flutter!.bundledDartExecutable,
      r'C:\src\flutter\bin\cache\dart-sdk\bin\dart.exe',
    );
  });

  test('a POSIX-style executable name is not accepted on Windows', () async {
    fs.files.add(r'C:\src\flutter\bin\flutter');
    final r = await SdkResolver(
      win({}),
      fileSystem: fs,
    ).resolve(projectDir: r'C:\proj\app', explicitSdkPath: r'C:\src\flutter');
    expect(r.flutter, isNull);
  });

  test('PATH lookup honours PATHEXT order and resolves flutter.bat', () async {
    fs.addSdk(r'C:\src\flutter');
    final r = await resolve(
      win({
        'PATH': r'C:\Windows;C:\src\flutter\bin',
        'PATHEXT': '.COM;.EXE;.BAT;.CMD',
      }),
    );
    expect(r.flutter!.sourceStep, 'path');
    expect(r.flutter!.root, r'C:\src\flutter');
    expect(r.flutter!.flutterExecutable, r'C:\src\flutter\bin\flutter.bat');
  });

  test('PATHEXT order: .exe launcher beats .bat when listed first', () async {
    fs.files
      ..add(r'C:\tools\flutter.exe')
      ..add(r'C:\tools\flutter.bat');
    final r = await resolve(win({'PATH': r'C:\tools', 'PATHEXT': '.EXE;.BAT'}));
    expect(r.flutter!.root, isNull);
    expect(r.flutter!.flutterExecutable, r'C:\tools\flutter.exe');
    final r2 = await resolve(
      win({'PATH': r'C:\tools', 'PATHEXT': '.BAT;.EXE'}),
    );
    expect(r2.flutter!.flutterExecutable, r'C:\tools\flutter.bat');
  });

  test('environment variable names are case-insensitive', () async {
    fs.addSdk(r'C:\src\flutter');
    final r = await resolve(win({'flutter_root': r'C:\src\flutter'}));
    expect(r.flutter!.sourceStep, 'flutter-root');
  });

  test(
    'fvm cache: FVM_CACHE_PATH, FVM_HOME, %USERPROFILE%\\fvm, %LOCALAPPDATA%\\fvm',
    () async {
      fs.text[r'C:\proj\.fvmrc'] = jsonEncode({'flutter': '3.24.0'});
      fs.dirs.add(r'C:\proj');
      fs.files.add(r'C:\proj\.fvmrc');
      final resolver = SdkResolver(
        win({
          'FVM_CACHE_PATH': r'D:\cache',
          'FVM_HOME': r'D:\fvmhome',
          'LOCALAPPDATA': r'C:\Users\Me\AppData\Local',
        }),
        fileSystem: fs,
      );
      expect(resolver.fvmCacheCandidates('3.24.0'), [
        r'D:\cache\versions\3.24.0',
        r'D:\fvmhome\versions\3.24.0',
        r'C:\Users\Me\fvm\versions\3.24.0',
        r'C:\Users\Me\AppData\Local\fvm\versions\3.24.0',
      ]);

      fs.addSdk(r'C:\Users\Me\AppData\Local\fvm\versions\3.24.0');
      final r = await SdkResolver(
        win({'LOCALAPPDATA': r'C:\Users\Me\AppData\Local'}),
        fileSystem: fs,
      ).resolve(projectDir: r'C:\proj\app');
      expect(r.flutter!.sourceStep, 'fvm-cache');
      expect(
        r.flutter!.flutterExecutable,
        r'C:\Users\Me\AppData\Local\fvm\versions\3.24.0\bin\flutter.bat',
      );
    },
  );

  test('fvm junction from an ancestor', () async {
    fs.addSdk(r'C:\Users\Me\fvm\versions\3.24.0');
    fs.links[r'C:\proj\.fvm\flutter_sdk'] = r'C:\Users\Me\fvm\versions\3.24.0';
    final r = await resolve(win({}));
    expect(r.flutter!.sourceStep, 'fvm-link');
    expect(r.flutter!.root, r'C:\Users\Me\fvm\versions\3.24.0');
  });

  test('puro: PURO_ROOT and %USERPROFILE%\\.puro', () async {
    fs.files.add(r'C:\proj\.puro.json');
    fs.text[r'C:\proj\.puro.json'] = '{"env":"main"}';
    fs.addSdk(r'C:\Users\Me\.puro\envs\main\flutter');
    var r = await resolve(win({}));
    expect(r.flutter!.sourceStep, 'puro');
    expect(
      r.flutter!.flutterExecutable,
      r'C:\Users\Me\.puro\envs\main\flutter\bin\flutter.bat',
    );

    fs.addSdk(r'E:\puro\envs\main\flutter');
    r = await resolve(win({'PURO_ROOT': r'E:\puro'}));
    expect(r.flutter!.root, r'E:\puro\envs\main\flutter');
  });

  test('dart kind uses dart.exe from the bundled SDK', () async {
    fs.addSdk(r'C:\src\flutter');
    final r = await resolve(
      win({'FLUTTER_ROOT': r'C:\src\flutter'}),
      kind: SdkKind.dart,
    );
    expect(r.dartExecutable, r'C:\src\flutter\bin\cache\dart-sdk\bin\dart.exe');
  });

  test('dart kind: DART_SDK and PATH use dart.exe', () async {
    fs.files.add(r'D:\dart\bin\dart.exe');
    var r = await resolve(win({'DART_SDK': r'D:\dart'}), kind: SdkKind.dart);
    expect(r.dartExecutable, r'D:\dart\bin\dart.exe');
    r = await resolve(win({'PATH': r'D:\dart\bin'}), kind: SdkKind.dart);
    expect(r.dartExecutable, r'D:\dart\bin\dart.exe');
  });
}
