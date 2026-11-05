import 'dart:io';

import 'package:flutter_run/src/common/errors.dart';
import 'package:flutter_run/src/common/host_environment.dart';
import 'package:flutter_run/src/init/project_detect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late HostEnvironment env;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rd_init_detect_');
    env = HostEnvironment(
      os: HostEnvironment.system().os,
      environment: const {},
      currentDirectory: tmp.path,
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  void write(String relative, String content) {
    final f = File(p.join(tmp.path, relative));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  test('Flutter app via sdk dependency', () {
    write('pubspec.yaml', '''
name: my_app
dependencies:
  flutter:
    sdk: flutter
''');
    final info = detectProject(tmp.path, env);
    expect(info.kind, ProjectKind.flutter);
    expect(info.name, 'my_app');
    expect(info.usesFvm, isFalse);
  });

  test('Flutter project via flutter: section only', () {
    write(
      'pubspec.yaml',
      'name: plugin_like\nflutter:\n  uses-material-design: true\n',
    );
    expect(detectProject(tmp.path, env).kind, ProjectKind.flutter);
  });

  test('Flutter project via environment.flutter', () {
    write(
      'pubspec.yaml',
      'name: x\nenvironment:\n  sdk: ^3.0.0\n  flutter: ">=3.0.0"\n',
    );
    expect(detectProject(tmp.path, env).kind, ProjectKind.flutter);
  });

  test('Dart package with bin/<name>.dart', () {
    write('pubspec.yaml', 'name: tool\nenvironment:\n  sdk: ^3.0.0\n');
    write('bin/tool.dart', 'void main() {}');
    write('bin/other.dart', 'void main() {}');
    final info = detectProject(tmp.path, env);
    expect(info.kind, ProjectKind.dart);
    expect(info.dartEntry, 'bin/tool.dart');
  });

  test('Dart entry fallbacks: main.dart, first file, lib/main.dart', () {
    write('pubspec.yaml', 'name: tool\n');
    expect(detectProject(tmp.path, env).dartEntry, 'lib/main.dart');
    write('bin/zeta.dart', '');
    write('bin/alpha.dart', '');
    expect(detectProject(tmp.path, env).dartEntry, 'bin/alpha.dart');
    write('bin/main.dart', '');
    expect(detectProject(tmp.path, env).dartEntry, 'bin/main.dart');
  });

  test('no pubspec throws ProjectNotFoundException (exit 8)', () {
    expect(
      () => detectProject(tmp.path, env),
      throwsA(
        isA<ProjectNotFoundException>().having(
          (e) => e.exitCode,
          'exitCode',
          ExitCodes.projectNotFound,
        ),
      ),
    );
  });

  test('finds the pubspec in an ancestor', () {
    write('pubspec.yaml', 'name: top\n');
    Directory(p.join(tmp.path, 'a', 'b')).createSync(recursive: true);
    expect(detectProject(p.join(tmp.path, 'a', 'b'), env).name, 'top');
  });

  test('fvm markers: .fvmrc and .fvm directory', () {
    write('pubspec.yaml', 'name: x\n');
    expect(detectProject(tmp.path, env).usesFvm, isFalse);
    write('.fvmrc', '{"flutter":"3.24.0"}');
    expect(detectProject(tmp.path, env).usesFvm, isTrue);
    File(p.join(tmp.path, '.fvmrc')).deleteSync();
    Directory(p.join(tmp.path, '.fvm')).createSync();
    expect(detectProject(tmp.path, env).usesFvm, isTrue);
  });

  test('invalid YAML is reported as an error with a hint', () {
    write('pubspec.yaml', 'name: [unclosed\n');
    expect(
      () => detectProject(tmp.path, env),
      throwsA(isA<ProjectNotFoundException>()),
    );
  });
}
