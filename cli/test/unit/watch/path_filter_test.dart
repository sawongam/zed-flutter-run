import 'package:flutter_run/src/common/host_environment.dart';
import 'package:flutter_run/src/watch/path_filter.dart';
import 'package:test/test.dart';

HostEnvironment _env(HostOs os, String cwd) =>
    HostEnvironment(os: os, environment: const {}, currentDirectory: cwd);

void main() {
  final linux = _env(HostOs.linux, '/work');
  final windows = _env(HostOs.windows, r'C:\work');

  group('PathFilter on posix', () {
    final filter = PathFilter(
      projectRoot: '/work/app',
      env: linux,
      globs: ['assets/**.json', 'l10n/*.arb'],
    );

    final table = <String, bool>{
      '/work/app/lib/main.dart': true,
      '/work/app/lib/a.g.dart': true,
      '/work/app/lib/src/deep/x.dart': true,
      '/work/app/bin/main.dart': true,
      '/work/app/lib/readme.md': false,
      '/work/app/lib/a.dart~': false,
      '/work/app/lib/a.dart.tmp': false,
      '/work/app/lib/.a.dart.swp': false,
      '/work/app/lib/.#a.dart': false,
      '/work/app/lib/.hidden/a.dart': false,
      '/work/app/.dart_tool/x.dart': false,
      '/work/app/lib/.dart_tool/x.dart': false,
      '/work/app/build/x.dart': false,
      '/work/app/lib/build/x.dart': true,
      '/work/app/lib/src/build/x.dart': true,
      '/work/app/.git/hooks/x.dart': false,
      '/work/app/node_modules/p/x.dart': false,
      '/work/app/ios/Pods/x.dart': true,
      '/work/other/lib/x.dart': false,
      '/work/app2/lib/x.dart': false,
      '/work/lib/x.dart': false,
      '/work/app/../x/lib/a.dart': false,
      '/work/app/assets/data/a.json': true,
      '/work/app/assets/a.json': true,
      '/work/app/assets/a.txt': false,
      '/work/app/build/assets/a.json': false,
      '/work/app/assets/.cache/a.json': false,
      '/work/app/l10n/app_en.arb': true,
      '/work/app/l10n/sub/app_en.arb': false,
      '/work/app': false,
      '/work/app/lib': false,
    };
    table.forEach((path, expected) {
      test('shouldTrigger $path -> $expected', () {
        expect(filter.shouldTrigger(path), expected);
      });
    });

    test('isIgnored', () {
      expect(filter.isIgnored('/work/app/build/x.dart'), isTrue);
      expect(filter.isIgnored('/work/app/lib/.x.dart'), isTrue);
      expect(filter.isIgnored('/other/x.dart'), isTrue);
      expect(filter.isIgnored('/work/app/lib/x.dart'), isFalse);
      expect(filter.isIgnored('/work/app/lib/x.txt'), isFalse);
    });

    test('hidden directories above the root do not matter', () {
      final f = PathFilter(projectRoot: '/home/u/.cache/build/app', env: linux);
      expect(f.shouldTrigger('/home/u/.cache/build/app/lib/a.dart'), isTrue);
    });

    test('Linux paths are case-sensitive', () {
      expect(filter.shouldTrigger('/work/app/Build/x.dart'), isTrue);
      expect(filter.shouldTrigger('/work/App/lib/x.dart'), isFalse);
    });

    test('relativePath uses forward slashes', () {
      expect(filter.relativePath('/work/app/lib/a.dart'), 'lib/a.dart');
      expect(filter.relativePath('/work/elsewhere/a.dart'), isNull);
    });
  });

  group('PathFilter with Windows paths', () {
    final filter = PathFilter(
      projectRoot: r'C:\work\app',
      env: windows,
      globs: [r'assets\**.json', 'l10n/*.arb'],
    );
    final table = <String, bool>{
      r'C:\work\app\lib\main.dart': true,
      r'c:\WORK\app\lib\main.dart': true,
      'C:/work/app/lib/main.dart': true,
      r'C:\work\app\lib\MAIN.DART': true,
      r'C:\work\app\lib\sub\a.dart': true,
      r'C:\work\app\build\a.dart': false,
      r'C:\work\app\BUILD\a.dart': false,
      r'C:\work\app\lib\Build\a.dart': true,
      r'C:\work\app\.dart_tool\a.dart': false,
      r'C:\work\app\lib\.hidden\a.dart': false,
      r'C:\work\other\lib\a.dart': false,
      r'D:\work\app\lib\a.dart': false,
      r'C:\work\app\assets\data\a.json': true,
      r'C:\work\app\ASSETS\a.json': true,
      r'C:\work\app\build\assets\a.json': false,
      r'C:\work\app\l10n\en.arb': true,
    };
    table.forEach((path, expected) {
      test('shouldTrigger $path -> $expected', () {
        expect(filter.shouldTrigger(path), expected);
      });
    });
    test('relativePath', () {
      expect(filter.relativePath(r'C:\work\app\lib\a\b.dart'), 'lib/a/b.dart');
    });
  });

  group('watchDirectories', () {
    List<String> dirs({
      bool dart = false,
      List<String> globs = const [],
      List<String>? rejected,
      HostEnvironment? env,
      String root = '/work/app',
    }) => PathFilter.watchDirectories(
      projectRoot: root,
      isDartProgram: dart,
      globs: globs,
      env: env ?? linux,
      rejectedGlobs: rejected,
    );

    test('flutter: lib only', () {
      expect(dirs(), ['/work/app/lib']);
    });
    test('dart: lib and bin', () {
      expect(dirs(dart: true), ['/work/app/lib', '/work/app/bin']);
    });
    test('glob prefixes', () {
      expect(dirs(globs: ['assets/**.json', 'l10n/*.arb', 'data/x/y/*.csv']), [
        '/work/app/lib',
        '/work/app/assets',
        '/work/app/l10n',
        '/work/app/data/x/y',
      ]);
    });
    test('prefix stops at the first wildcard segment', () {
      expect(dirs(globs: ['a/b*/c/*.x']), ['/work/app/lib', '/work/app/a']);
    });
    test('literal file glob watches its folder', () {
      expect(dirs(globs: ['config/app.yaml']), [
        '/work/app/lib',
        '/work/app/config',
      ]);
    });
    test('prefix inside an already watched folder is merged', () {
      expect(dirs(globs: ['lib/gen/*.json']), ['/work/app/lib']);
      expect(dirs(globs: ['assets/img/*.png', 'assets/*.json']), [
        '/work/app/lib',
        '/work/app/assets',
      ]);
    });
    test('globs without a folder prefix are rejected', () {
      final rejected = <String>[];
      final result = dirs(
        globs: ['**.json', '*.arb', '{a,b}/x.y', 'assets/**.json'],
        rejected: rejected,
      );
      expect(result, ['/work/app/lib', '/work/app/assets']);
      expect(rejected, ['**.json', '*.arb', '{a,b}/x.y']);
    });
    test('never ios, android, build or hidden folders', () {
      final rejected = <String>[];
      final result = dirs(
        dart: true,
        globs: [
          'build/x/*.json',
          '.dart_tool/*.json',
          'ios/Pods/**.h',
          'android/.gradle/*.x',
          '../outside/*.x',
          '/abs/*.x',
        ],
        rejected: rejected,
      );
      expect(result, ['/work/app/lib', '/work/app/bin']);
      expect(rejected, hasLength(6));
      for (final d in result) {
        expect(d, isNot(contains('ios')));
        expect(d, isNot(contains('android')));
        expect(d, isNot(contains('build')));
      }
    });
    test('windows root and backslash globs', () {
      expect(
        dirs(
          env: windows,
          root: r'C:\work\app',
          globs: [r'assets\sub\**.json'],
        ),
        [r'C:\work\app\lib', r'C:\work\app\assets\sub'],
      );
    });
  });
}
