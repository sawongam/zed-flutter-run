import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_run/src/common/console.dart';
import 'package:flutter_run/src/common/errors.dart';
import 'package:flutter_run/src/common/host_environment.dart';
import 'package:flutter_run/src/init/commands/keymap_command.dart';
import 'package:flutter_run/src/init/jsonc.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late MemoryConsole console;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rd_keymap_cmd_');
    console = MemoryConsole();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  String zedDir(HostOs os) => os == HostOs.windows
      ? p.join(tmp.path, 'appdata', 'Zed')
      : p.join(tmp.path, 'home', '.config', 'zed');

  Future<int> run(
    List<String> args, {
    HostOs os = HostOs.linux,
    Map<String, String>? environment,
  }) async {
    final env = HostEnvironment(
      os: os,
      environment:
          environment ??
          {
            'HOME': p.join(tmp.path, 'home'),
            'USERPROFILE': p.join(tmp.path, 'home'),
            'APPDATA': p.join(tmp.path, 'appdata'),
          },
      currentDirectory: tmp.path,
    );
    final runner = CommandRunner<int>('flutter_run', 'test')
      ..addCommand(KeymapCommand(env: env, console: console));
    return (await runner.run(['keymap', ...args]))!;
  }

  String keymap([HostOs os = HostOs.linux]) =>
      File(p.join(zedDir(os), 'keymap.json')).readAsStringSync();
  void writeZed(String name, String content, [HostOs os = HostOs.linux]) {
    Directory(zedDir(os)).createSync(recursive: true);
    File(p.join(zedDir(os), name)).writeAsStringSync(content);
  }

  String out() => console.outLines.join('\n');

  Map<String, Object?> bindingsOf(Object? keymapJson) {
    final blocks = keymapJson! as List<Object?>;
    return (blocks.last! as Map<String, Object?>)['bindings']!
        as Map<String, Object?>;
  }

  test('creates the keymap with the default keys', () async {
    expect(await run([]), ExitCodes.ok);
    final decoded = decodeJsonc(keymap());
    final block = (decoded! as List<Object?>).single! as Map<String, Object?>;
    expect(block['context'], 'Workspace && debugger_session');
    expect(bindingsOf(decoded).keys, [
      'ctrl-f5',
      'ctrl-shift-f5',
      'ctrl-alt-shift-d',
    ]);
    expect(out(), contains('Added these keys to'));
    expect(out(), contains('restart Zed'));
    expect(out(), contains('Fn Lock'));
  });

  test('appends to a keymap with comments and keeps them', () async {
    writeZed(
      'keymap.json',
      '// Zed keymap\n[\n  {\n    "bindings": {"ctrl-k": "menu::Cancel"}\n  }\n]\n',
    );
    expect(await run([]), ExitCodes.ok);
    final text = keymap();
    expect(text, startsWith('// Zed keymap\n'));
    expect(text, contains('menu::Cancel'));
    expect(decodeJsonc(text), hasLength(2));
  });

  test('custom keys in either form', () async {
    expect(
      await run([
        '--reload-key',
        'Ctrl+S',
        '--restart-key',
        'ctrl-shift-s',
        '--devtools-key',
        'ctrl-alt-shift-d',
      ]),
      ExitCodes.ok,
    );
    expect(bindingsOf(decodeJsonc(keymap())).keys, [
      'ctrl-s',
      'ctrl-shift-s',
      'ctrl-alt-shift-d',
    ]);
    expect(out(), contains('is Save. During a debug session'));
    expect(out(), contains('is Save As'));
    expect(out(), isNot(contains('Fn Lock')));
  });

  test('a bad key is a usage error', () async {
    await expectLater(
      run(['--reload-key', 'hyper-s']),
      throwsA(isA<UsageError>()),
    );
  });

  test('one key for two actions is a usage error', () async {
    await expectLater(
      run(['--reload-key', 'ctrl-r', '--restart-key', 'Ctrl+R']),
      throwsA(isA<UsageError>()),
    );
  });

  test('--keep-zed-restart-key leaves out hot restart', () async {
    await run(['--keep-zed-restart-key']);
    expect(
      bindingsOf(decodeJsonc(keymap())).keys,
      isNot(contains('ctrl-shift-f5')),
    );
  });

  test('macOS uses shift-cmd-f5 and the macOS notes', () async {
    await run([], os: HostOs.macos);
    expect(
      bindingsOf(decodeJsonc(keymap(HostOs.macos))).keys,
      contains('shift-cmd-f5'),
    );
    expect(out(), contains('Use F1, F2'));
    expect(out(), contains('toolbar'));
  });

  test(r'Windows uses %APPDATA%\Zed', () async {
    // Windows path rules on any host: only check the path that is shown.
    await run(['--dry-run'], os: HostOs.windows);
    expect(out(), contains(r'appdata\Zed\keymap.json'));
  });

  test('XDG_CONFIG_HOME is used on Linux', () async {
    final xdg = p.join(tmp.path, 'xdg');
    await run(
      [],
      environment: {'HOME': p.join(tmp.path, 'home'), 'XDG_CONFIG_HOME': xdg},
    );
    expect(File(p.join(xdg, 'zed', 'keymap.json')).existsSync(), isTrue);
  });

  test('--file overrides the location', () async {
    // The host's path rules must match the real file system, or a Windows
    // path would be read as relative.
    final os = Platform.isWindows ? HostOs.windows : HostOs.linux;
    final path = p.join(tmp.path, 'mine.json');
    await run(['--file', path], os: os);
    expect(File(path).existsSync(), isTrue);
  });

  test('warns about the base keymap from Zed settings', () async {
    writeZed(
      'settings.json',
      '{\n  // mine\n  "base_keymap": "JetBrains",\n}\n',
    );
    await run([]);
    expect(out(), contains('JetBrains keymap uses Ctrl+F5'));
  });

  test('a second run changes nothing and lists the keys', () async {
    await run([]);
    final first = keymap();
    console.outLines.clear();
    expect(await run(['--reload-key', 'ctrl-r']), ExitCodes.ok);
    expect(keymap(), first);
    expect(out(), contains('already has Flutter keys'));
    expect(out(), contains('Ctrl+F5'));
  });

  test('--dry-run writes nothing', () async {
    expect(await run(['--dry-run']), ExitCodes.ok);
    expect(
      File(p.join(zedDir(HostOs.linux), 'keymap.json')).existsSync(),
      isFalse,
    );
    expect(out(), contains('Would add these keys'));
    expect(out(), contains('"task_name": "Flutter: Hot Reload"'));
  });

  test('an invalid keymap is left alone (exit 9)', () async {
    writeZed('keymap.json', '[ not json');
    expect(await run([]), ExitCodes.manualActionRequired);
    expect(keymap(), '[ not json');
    expect(out(), contains('Could not safely edit'));
    expect(out(), contains('task::Spawn'));
  });
}
