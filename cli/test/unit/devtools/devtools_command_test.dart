import 'package:args/command_runner.dart';
import 'package:flutter_run/src/common/console.dart';
import 'package:flutter_run/src/common/errors.dart';
import 'package:flutter_run/src/common/host_environment.dart';
import 'package:flutter_run/src/devtools/browser_opener.dart';
import 'package:flutter_run/src/devtools/commands/devtools_command.dart';
import 'package:test/test.dart';

class _Opener implements BrowserOpener {
  final opened = <Uri>[];
  Object? failure;
  @override
  Future<void> open(Uri url) async {
    if (failure != null) throw failure!;
    opened.add(url);
  }
}

void main() {
  late MemoryConsole console;
  late _Opener opener;
  late List<String> askedDirs;
  late Future<VmServiceTarget> Function() onResolve;

  Future<int> run(List<String> args) async {
    final runner = CommandRunner<int>('flutter_run', 'test')
      ..addCommand(
        DevToolsCommand(
          resolveTarget: ({required directory}) {
            askedDirs.add(directory);
            return onResolve();
          },
          opener: opener,
          env: HostEnvironment(
            os: HostOs.linux,
            environment: const {},
            currentDirectory: '/work/app',
          ),
          console: console,
        ),
      );
    return (await runner.run(['devtools', ...args])) ?? 0;
  }

  setUp(() {
    console = MemoryConsole();
    opener = _Opener();
    askedDirs = [];
    onResolve = () async => const VmServiceTarget(
      vmServiceUri: 'ws://127.0.0.1:7/tok=/ws',
      deviceId: 'linux',
      sessionPid: 42,
    );
  });

  const inspectorUrl =
      'http://127.0.0.1:7/tok=/devtools/inspector'
      '?uri=ws%3A%2F%2F127.0.0.1%3A7%2Ftok%3D%2Fws';

  test('default prints Opening DevTools: url, then opens inspector', () async {
    expect(await run([]), 0);
    expect(console.outLines, ['Opening DevTools: $inspectorUrl']);
    expect(opener.opened.map((u) => u.toString()), [inspectorUrl]);
    expect(askedDirs, ['/work/app']);
  });

  test('page argument and --project', () async {
    expect(await run(['--project', '/p', 'cpu_profiler']), 0);
    expect(opener.opened.single.path, '/tok=/devtools/cpu-profiler');
    expect(askedDirs, ['/p']);
  });

  test('--print prints only the URL and opens nothing', () async {
    expect(await run(['--print', 'memory']), 0);
    expect(console.outLines, hasLength(1));
    expect(console.outLines.single, startsWith('http://127.0.0.1:7/tok=/'));
    expect(console.outLines.single, contains('/devtools/memory?uri='));
    expect(opener.opened, isEmpty);
  });

  test('browser failure keeps URL printed and returns 10', () async {
    opener.failure = const ExternalToolException('no browser');
    expect(await run([]), 10);
    expect(console.outLines, ['Opening DevTools: $inspectorUrl']);
    expect(console.errLines.join('\n'), contains('no browser'));
    expect(console.errLines.join('\n'), contains('Development Service'));
  });

  test('refusal suggests --print, not the DDS hint', () async {
    opener.failure = const BrowserRefusedException('Refusing to open x.');
    expect(await run([]), 10);
    final err = console.errLines.join('\n');
    expect(err, contains('devtools --print'));
    expect(err, isNot(contains('Development Service')));
  });

  test('no session propagates exit 3', () async {
    onResolve = () async => throw const NoSessionException('none');
    await expectLater(
      run([]),
      throwsA(isA<NoSessionException>().having((e) => e.exitCode, 'c', 3)),
    );
    expect(opener.opened, isEmpty);
  });

  test('session without URI propagates exit 4', () async {
    onResolve = () async => throw const SessionRequestException(
      'The app is still starting. Try again in a moment.',
    );
    await expectLater(
      run([]),
      throwsA(
        isA<SessionRequestException>()
            .having((e) => e.exitCode, 'c', 4)
            .having((e) => e.message, 'm', contains('still starting')),
      ),
    );
  });

  test('dart session is refused with exit 4 and prints the address', () async {
    onResolve = () async => const VmServiceTarget(
      vmServiceUri: 'ws://127.0.0.1:7/tok=/ws',
      sessionPid: 1,
      kind: 'dart',
    );
    await expectLater(
      run([]),
      throwsA(
        isA<SessionRequestException>()
            .having((e) => e.exitCode, 'c', 4)
            .having(
              (e) => e.hint,
              'hint',
              allOf(
                contains('dart devtools'),
                contains('ws://127.0.0.1:7/tok=/ws'),
              ),
            ),
      ),
    );
    expect(opener.opened, isEmpty);
  });

  test('unknown page is a usage error (2)', () async {
    await expectLater(
      run(['bogus']),
      throwsA(isA<UsageError>().having((e) => e.exitCode, 'c', 2)),
    );
    expect(askedDirs, isEmpty);
  });

  test('too many arguments is a usage error', () async {
    await expectLater(run(['inspector', 'memory']), throwsA(isA<UsageError>()));
  });

  test('unusable address from the session is exit 4', () async {
    onResolve = () async =>
        const VmServiceTarget(vmServiceUri: 'junk', sessionPid: 1);
    await expectLater(run([]), throwsA(isA<SessionRequestException>()));
  });
}
