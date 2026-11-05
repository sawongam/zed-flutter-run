import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_run/src/common/console.dart';
import 'package:flutter_run/src/common/errors.dart';
import 'package:flutter_run/src/common/host_environment.dart';
import 'package:flutter_run/src/init/commands/init_command.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late MemoryConsole console;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rd_init_cmd_');
    console = MemoryConsole();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  HostEnvironment hostEnv([HostOs? os]) => HostEnvironment(
    os: os ?? HostEnvironment.system().os,
    environment: const {},
    currentDirectory: tmp.path,
  );

  void writeProject({bool flutter = true}) {
    File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync(
      flutter
          ? 'name: app\ndependencies:\n  flutter:\n    sdk: flutter\n'
          : 'name: tool\n',
    );
  }

  String zed(String name) => p.join(tmp.path, '.zed', name);
  String read(String name) => File(zed(name)).readAsStringSync();
  String out() => console.outLines.join('\n');

  Future<int> run(
    List<String> args, {
    String? onPath,
    HostOs? os,
    String hint = 'Add the folder to PATH.',
  }) async {
    final runner = CommandRunner<int>('flutter_run', 'test')
      ..addCommand(
        InitCommand(
          env: hostEnv(os),
          console: console,
          findFlutterRunOnPath: () => onPath,
          pathFixHint: hint,
        ),
      );
    return (await runner.run(['init', ...args]))!;
  }

  test('creates both files with the planned labels', () async {
    writeProject();
    expect(await run([]), 0);
    final debug = jsonDecode(read('debug.json')) as List<Object?>;
    final tasks = jsonDecode(read('tasks.json')) as List<Object?>;
    String l(Object? x) => (x! as Map<String, Object?>)['label']! as String;
    expect(debug.map(l), [
      'Flutter: Debug',
      'Flutter: Run (no debug)',
      'Flutter: Profile',
      'Flutter: Attach',
    ]);
    expect(tasks, hasLength(9));
    expect(read('debug.json'), endsWith('\n'));
    expect(read('debug.json'), isNot(contains('\r')));
    expect(out(), contains('Created .zed/debug.json with 4 entries.'));
  });

  test('Dart package gets one scenario and only Doctor', () async {
    writeProject(flutter: false);
    expect(await run([]), 0);
    expect(jsonDecode(read('debug.json')), hasLength(1));
    final tasks = jsonDecode(read('tasks.json')) as List<Object?>;
    expect((tasks.single! as Map<String, Object?>)['label'], 'Flutter: Doctor');
  });

  test('no pubspec -> exit 8', () async {
    await expectLater(
      run([]),
      throwsA(
        isA<ProjectNotFoundException>().having(
          (e) => e.exitCode,
          'exit',
          ExitCodes.projectNotFound,
        ),
      ),
    );
    expect(Directory(p.join(tmp.path, '.zed')).existsSync(), isFalse);
  });

  test('--project selects the directory', () async {
    final sub = Directory(p.join(tmp.path, 'sub'))..createSync();
    File(p.join(sub.path, 'pubspec.yaml')).writeAsStringSync('name: s\n');
    expect(await run(['--project', sub.path]), 0);
    expect(File(p.join(sub.path, '.zed', 'tasks.json')).existsSync(), isTrue);
  });

  test('idempotent: second run changes nothing', () async {
    writeProject();
    await run([]);
    final before = [read('debug.json'), read('tasks.json')];
    final stamps = [
      File(zed('debug.json')).lastModifiedSync(),
      File(zed('tasks.json')).lastModifiedSync(),
    ];
    console.outLines.clear();
    expect(await run([]), 0);
    expect([read('debug.json'), read('tasks.json')], before);
    expect([
      File(zed('debug.json')).lastModifiedSync(),
      File(zed('tasks.json')).lastModifiedSync(),
    ], stamps);
    expect(out(), contains('Added 0 entries, kept 4 that were already there.'));
    expect(out(), contains('Added 0 entries, kept 9 that were already there.'));
  });

  test('merges into an existing strict JSON file', () async {
    writeProject();
    Directory(p.join(tmp.path, '.zed')).createSync();
    File(zed('debug.json')).writeAsStringSync(
      '[{"label":"Mine","adapter":"Other"},{"label":"Flutter: Debug","custom":1}]',
    );
    expect(await run([]), 0);
    final list = jsonDecode(read('debug.json')) as List<Object?>;
    final labels = list
        .map((e) => (e! as Map<String, Object?>)['label'])
        .toList();
    expect(labels, [
      'Mine',
      'Flutter: Debug',
      'Flutter: Run (no debug)',
      'Flutter: Profile',
      'Flutter: Attach',
    ]);
    expect((list[1]! as Map<String, Object?>)['custom'], 1);
    expect(out(), contains('Added 3 entries, kept 1 that was already there.'));
  });

  test('--dry-run writes nothing', () async {
    writeProject();
    expect(await run(['--dry-run']), 0);
    expect(Directory(p.join(tmp.path, '.zed')).existsSync(), isFalse);
    expect(out(), contains('Would create .zed/debug.json'));
    expect(out(), contains('Dry run: nothing was written.'));
    expect(out(), contains('"label": "Flutter: Hot Reload"'));
  });

  test('--dry-run leaves existing files alone', () async {
    writeProject();
    Directory(p.join(tmp.path, '.zed')).createSync();
    File(zed('debug.json')).writeAsStringSync('[]');
    await run(['--dry-run']);
    expect(read('debug.json'), '[]');
    expect(File(zed('tasks.json')).existsSync(), isFalse);
  });

  test('JSONC file is untouched, snippet printed, exit 9', () async {
    writeProject();
    Directory(p.join(tmp.path, '.zed')).createSync();
    const jsonc = '// my scenarios\n[]\n';
    File(zed('debug.json')).writeAsStringSync(jsonc);
    expect(await run([]), ExitCodes.manualActionRequired);
    expect(read('debug.json'), jsonc);
    expect(File(zed('tasks.json')).existsSync(), isTrue);
    expect(
      out(),
      contains(
        'Could not safely edit .zed/debug.json (it has comments or trailing commas). Nothing was changed. Paste these entries into the file:',
      ),
    );
    expect(out(), contains('"label": "Flutter: Debug"'));
    expect(out(), contains('Zed puts in new files'));
    expect(out().trimRight(), endsWith('Done with 1 manual step.'));
    expect(
      Directory(zed('')).listSync().map((f) => p.basename(f.path)),
      isNot(contains('debug.json.bak')),
    );
  });

  test('root-object file counts as invalid', () async {
    writeProject();
    Directory(p.join(tmp.path, '.zed')).createSync();
    File(zed('tasks.json')).writeAsStringSync('{"a":1}');
    expect(await run([]), ExitCodes.manualActionRequired);
    expect(read('tasks.json'), '{"a":1}');
  });

  test('both files invalid: two manual steps', () async {
    writeProject();
    Directory(p.join(tmp.path, '.zed')).createSync();
    File(zed('debug.json')).writeAsStringSync('// a\n[]');
    File(zed('tasks.json')).writeAsStringSync('[,]');
    expect(await run([]), 9);
    expect(out(), contains('Done with 2 manual steps.'));
  });

  test('--force backs up (numbered) then overwrites', () async {
    writeProject();
    Directory(p.join(tmp.path, '.zed')).createSync();
    File(zed('debug.json')).writeAsStringSync('// one\n[]');
    expect(await run(['--force']), 0);
    expect(File(zed('debug.json.bak')).readAsStringSync(), '// one\n[]');
    expect(jsonDecode(read('debug.json')), hasLength(4));
    expect(out(), contains('Backed up to debug.json.bak'));

    File(zed('debug.json')).writeAsStringSync('// two\n[]');
    console.outLines.clear();
    expect(await run(['--force']), 0);
    expect(File(zed('debug.json.bak')).readAsStringSync(), '// one\n[]');
    expect(File(zed('debug.json.bak.1')).readAsStringSync(), '// two\n[]');
    expect(out(), contains('Backed up to debug.json.bak.1'));
  });

  test('--force --dry-run writes nothing', () async {
    writeProject();
    Directory(p.join(tmp.path, '.zed')).createSync();
    File(zed('debug.json')).writeAsStringSync('// x\n[]');
    await run(['--force', '--dry-run']);
    expect(read('debug.json'), '// x\n[]');
    expect(File(zed('debug.json.bak')).existsSync(), isFalse);
  });

  test('prints key table, keymap steps and console note', () async {
    writeProject();
    await run([]);
    final text = out();
    expect(text, contains('F4'));
    expect(text, contains('F5 does nothing while the app runs'));
    expect(
      text,
      contains(
        'Open the command palette, run "zed: open keymap file", and paste the snippet.',
      ),
    );
    expect(text, contains('"context": "Workspace && debugger_session"'));
    expect(
      text,
      contains(
        'Output and reload results appear in the Console tab of the Debug panel.',
      ),
    );
    expect(text, contains('usually committed'));
  });

  test('macOS note only on macOS', () async {
    writeProject();
    await run([], os: HostOs.macos);
    expect(out(), contains('Use F1, F2'));
    expect(out(), contains('shift-cmd-f5'));
    console.outLines.clear();
    await run([], os: HostOs.linux);
    expect(out(), isNot(contains('Use F1, F2')));
  });

  test('PATH check: found', () async {
    writeProject();
    await run([], onPath: '/usr/local/bin/flutter_run');
    expect(
      out(),
      contains('flutter_run on PATH: yes (/usr/local/bin/flutter_run)'),
    );
    expect(out(), isNot(contains('Add the folder to PATH.')));
  });

  test('PATH check: missing shows the hint', () async {
    writeProject();
    await run([]);
    expect(out(), contains('flutter_run on PATH: no'));
    expect(out(), contains('Warning:'));
    expect(out(), contains('Add the folder to PATH.'));
  });

  test('fvm is reported only', () async {
    writeProject();
    File(p.join(tmp.path, '.fvmrc')).writeAsStringSync('{"flutter":"stable"}');
    await run([]);
    expect(out(), contains('fvm'));
  });
}
