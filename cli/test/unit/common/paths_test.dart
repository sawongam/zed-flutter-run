import 'dart:io';

import 'package:flutter_run/src/common/errors.dart';
import 'package:flutter_run/src/common/host_environment.dart';
import 'package:flutter_run/src/common/paths.dart';
import 'package:test/test.dart';

HostEnvironment fake(
  HostOs os, {
  Map<String, String> env = const {},
  String cwd = '/work',
}) => HostEnvironment(os: os, environment: env, currentDirectory: cwd);

void main() {
  final win = fake(HostOs.windows, cwd: r'C:\Users\Me');
  final mac = fake(HostOs.macos);
  final linux = fake(HostOs.linux);

  group('pathKey / pathsEqual (windows)', () {
    test('case-insensitive, separators and trailing separators', () {
      expect(pathsEqual(r'C:\Users\Me\App', r'c:\users\me\app', win), isTrue);
      expect(pathsEqual(r'C:\Users\Me\App\', r'C:\Users\Me\App', win), isTrue);
      expect(pathsEqual('C:/Users/Me/App', r'C:\Users\Me\App', win), isTrue);
      expect(
        pathsEqual(r'C:\Users\Me\a\..\App', r'C:\Users\Me\App', win),
        isTrue,
      );
      expect(
        pathsEqual(r'C:\Users\Me\App', r'C:\Users\Me\Other', win),
        isFalse,
      );
    });
    test('relative paths resolve against the current directory', () {
      expect(pathKey('App', win), r'c:\users\me\app');
    });
    test('isWithin', () {
      expect(isWithin(r'C:\A\B', r'c:\a\b\c', win), isTrue);
      expect(isWithin(r'C:\A\B', r'C:\A\BC', win), isFalse);
      expect(isWithin(r'C:\A\B', r'C:\A\B\', win), isTrue);
    });
  });

  group('posix / macos', () {
    test('linux is case-sensitive, macos is not', () {
      expect(pathsEqual('/A/b', '/a/b', linux), isFalse);
      expect(pathsEqual('/A/b', '/a/b', mac), isTrue);
    });
    test('isWithin edge cases', () {
      expect(isWithin('/a/b', '/a/bc', linux), isFalse);
      expect(isWithin('/a/b', '/a/b', linux), isTrue);
      expect(isWithin('/a/b', '/a/b/', linux), isTrue);
      expect(isWithin('/a/b', '/a/b/c/d', linux), isTrue);
      expect(isWithin('/a/b/c', '/a/b', linux), isFalse);
      expect(isWithin('/a/b', '/a/b/../x', linux), isFalse);
      expect(isWithin('/', '/a', linux), isTrue);
    });
  });

  group('canonicalDirectory', () {
    test('pure normalisation for a fake non-host OS', () {
      final other = Platform.isWindows ? linux : win;
      final path = Platform.isWindows ? '/a/b/../c/' : r'C:\a\b\..\c\';
      expect(
        canonicalDirectory(path, other),
        Platform.isWindows ? '/a/c' : r'C:\a\c',
      );
    });
    test('resolves symlinks on the host', () {
      if (Platform.isWindows) return;
      final tmp = Directory.systemTemp.createTempSync('rd_canon');
      addTearDown(() => tmp.deleteSync(recursive: true));
      Directory('${tmp.path}/real').createSync();
      Link('${tmp.path}/link').createSync('${tmp.path}/real');
      final env = HostEnvironment.system();
      final real = Directory('${tmp.path}/real').resolveSymbolicLinksSync();
      expect(canonicalDirectory('${tmp.path}/link/', env), real);
      expect(canonicalDirectory('${tmp.path}/missing/../real', env), real);
    });
  });

  group('projectRootHash', () {
    test('16 hex chars, stable across case on windows', () {
      final h = projectRootHash(r'C:\Users\Me\App', win);
      expect(h, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(projectRootHash(r'c:\users\me\app\', win), h);
      expect(
        projectRootHash('/a/b', linux),
        isNot(projectRootHash('/a/c', linux)),
      );
    });
  });

  group('findProjectRoot / findUpwards', () {
    late Directory tmp;
    late HostEnvironment env;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('rd_root');
      env = HostEnvironment.system();
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('finds the nearest ancestor with pubspec.yaml', () {
      File('${tmp.path}/pubspec.yaml').createSync();
      Directory('${tmp.path}/app/lib/deep').createSync(recursive: true);
      File('${tmp.path}/app/pubspec.yaml').createSync();
      final app = env.pathContext.join(tmp.path, 'app');
      expect(findProjectRoot('${tmp.path}/app/lib/deep', env), app);
      expect(findProjectRoot('${tmp.path}/app', env), app);
      expect(findProjectRoot(tmp.path, env), tmp.path);
    });

    test('returns null when nothing is found', () {
      Directory('${tmp.path}/x').createSync();
      // Temp dirs normally have no pubspec.yaml above them.
      final result = findProjectRoot('${tmp.path}/x', env);
      expect(result == null || !result.startsWith(tmp.path), isTrue);
    });

    test('findUpwards finds files, directories and links', () {
      Directory('${tmp.path}/.fvm').createSync();
      Directory('${tmp.path}/a/b').createSync(recursive: true);
      expect(
        findUpwards('${tmp.path}/a/b', '.fvm', env),
        env.pathContext.join(tmp.path, '.fvm'),
      );
      expect(
        findUpwards('${tmp.path}/a/b', '.nonexistent-rd-file', env),
        isNull,
      );
    });
  });

  group('findExecutableOnPath', () {
    test('posix: first hit with an execute bit', () {
      if (Platform.isWindows) return;
      final a = Directory.systemTemp.createTempSync('rd_pa');
      final b = Directory.systemTemp.createTempSync('rd_pb');
      addTearDown(() {
        a.deleteSync(recursive: true);
        b.deleteSync(recursive: true);
      });
      File('${a.path}/tool').writeAsStringSync('x');
      Process.runSync('chmod', ['644', '${a.path}/tool']);
      File('${b.path}/tool').writeAsStringSync('x');
      Process.runSync('chmod', ['755', '${b.path}/tool']);
      final env = fake(HostOs.linux, env: {'PATH': '::${a.path}:${b.path}'});
      expect(findExecutableOnPath('tool', env), '${b.path}/tool');
      expect(findExecutableOnPath('missing', env), isNull);
      expect(findExecutableOnPath('tool', fake(HostOs.linux)), isNull);
    });

    test('windows: PATHEXT order and directory order', () {
      final present = {
        r'C:\one\flutter.bat',
        r'C:\one\flutter.cmd',
        r'C:\two\flutter.exe',
      };
      final env = fake(
        HostOs.windows,
        cwd: r'C:\w',
        env: {'Path': r'C:\one;"C:\two"', 'pathext': '.EXE;.BAT;.CMD'},
      );
      expect(
        findExecutableOnPath(
          'flutter',
          env,
          isExecutableFile: present.contains,
        ),
        r'C:\one\flutter.bat',
      );
      expect(
        findExecutableOnPath(
          'flutter',
          env.copyWith(
            environment: {'Path': r'C:\two;C:\one', 'PATHEXT': '.EXE;.BAT'},
          ),
          isExecutableFile: present.contains,
        ),
        r'C:\two\flutter.exe',
      );
      expect(
        findExecutableOnPath(
          'flutter',
          env.copyWith(
            environment: {'PATH': r'C:\one', 'PATHEXT': '.CMD;.BAT'},
          ),
          isExecutableFile: present.contains,
        ),
        r'C:\one\flutter.cmd',
      );
    });

    test('windows: default PATHEXT and explicit extension', () {
      final present = {r'C:\one\flutter.bat', r'C:\one\tool.exe'};
      final env = fake(HostOs.windows, cwd: r'C:\w', env: {'PATH': r'C:\one'});
      expect(
        findExecutableOnPath(
          'flutter',
          env,
          isExecutableFile: present.contains,
        ),
        r'C:\one\flutter.bat',
      );
      expect(
        findExecutableOnPath(
          'tool.exe',
          env,
          isExecutableFile: present.contains,
        ),
        r'C:\one\tool.exe',
      );
      expect(
        findExecutableOnPath(
          'flutter.txt',
          env,
          isExecutableFile: present.contains,
        ),
        isNull,
      );
    });
  });

  group('stateBaseDirectory', () {
    test('override wins', () {
      expect(
        stateBaseDirectory(
          fake(HostOs.linux, env: {'FLUTTER_RUN_STATE_DIR': '/s'}),
        ),
        '/s',
      );
    });
    test('linux: XDG then ~/.local/state', () {
      expect(
        stateBaseDirectory(
          fake(HostOs.linux, env: {'XDG_STATE_HOME': '/x', 'HOME': '/h'}),
        ),
        '/x/flutter_run',
      );
      expect(
        stateBaseDirectory(fake(HostOs.linux, env: {'HOME': '/h'})),
        '/h/.local/state/flutter_run',
      );
    });
    test('macos', () {
      expect(
        stateBaseDirectory(fake(HostOs.macos, env: {'HOME': '/Users/me'})),
        '/Users/me/Library/Application Support/flutter_run',
      );
    });
    test('windows', () {
      expect(
        stateBaseDirectory(
          fake(
            HostOs.windows,
            cwd: r'C:\w',
            env: {'LOCALAPPDATA': r'C:\Users\Me\AppData\Local'},
          ),
        ),
        r'C:\Users\Me\AppData\Local\flutter_run',
      );
      expect(
        stateBaseDirectory(
          fake(
            HostOs.windows,
            cwd: r'C:\w',
            env: {'USERPROFILE': r'C:\Users\Me'},
          ),
        ),
        r'C:\Users\Me\AppData\Local\flutter_run',
      );
    });
    test('no home throws a friendly error', () {
      expect(
        () => stateBaseDirectory(fake(HostOs.linux)),
        throwsA(isA<FlutterRunException>()),
      );
    });
  });
}
