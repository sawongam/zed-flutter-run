import 'package:args/command_runner.dart';
import 'package:flutter_run/src/cli/runner.dart';
import 'package:flutter_run/src/common/errors.dart';
import 'package:test/test.dart';

import 'support.dart';

class _ThrowingCommand extends Command<int> {
  _ThrowingCommand(this.error);

  final Object error;

  @override
  String get name => 'boom';

  @override
  String get description => 'throws';

  @override
  Future<int> run() async => throw error;
}

void main() {
  late TestWiring t;
  late FlutterRunRunner runner;

  setUp(() {
    t = TestWiring();
    runner = FlutterRunRunner(wiring: t.wiring, flushOutput: () async {});
  });

  tearDown(() => t.dispose());

  test('version prints the tool name and version', () async {
    expect(await runner.execute(['version']), 0);
    expect(t.console.outLines, ['flutter_run 0.1.0']);
  });

  test('--version and -V print the same as the version command', () async {
    expect(await runner.execute(['--version']), 0);
    expect(await runner.execute(['-V']), 0);
    expect(t.console.outLines, ['flutter_run 0.1.0', 'flutter_run 0.1.0']);
  });

  test(
    'an unknown command is a usage error (exit 2) with the usage text',
    () async {
      expect(await runner.execute(['frobnicate']), ExitCodes.usage);
      expect(t.console.errLines.join('\n'), contains('frobnicate'));
      expect(t.console.errLines.join('\n'), contains('Usage: flutter_run'));
    },
  );

  test('an unknown flag is a usage error (exit 2)', () async {
    expect(await runner.execute(['version', '--nope']), ExitCodes.usage);
  });

  test('dap without --cwd is a usage error (exit 2)', () async {
    expect(await runner.execute(['dap']), ExitCodes.usage);
    expect(t.console.errLines.join('\n'), contains('--cwd'));
  });

  test('--help is a success', () async {
    expect(await runner.execute(['--help']), 0);
  });

  test('help text lists the exit codes', () {
    expect(runner.usage, contains('Exit codes:'));
    expect(runner.usage, contains('130  Interrupted'));
  });

  test(
    'a FlutterRunException maps to its exit code with message and hint',
    () async {
      runner.addCommand(
        _ThrowingCommand(
          const NoSessionException('No app.', hint: 'Start one first.'),
        ),
      );
      expect(await runner.execute(['boom']), ExitCodes.noSession);
      expect(t.console.errLines, ['error: No app.', 'hint: Start one first.']);
    },
  );

  test('every exception class keeps its own exit code', () async {
    const errors = <FlutterRunException, int>{
      SdkNotFoundException('x'): 6,
      DeviceException('x'): 7,
      ProjectNotFoundException('x'): 8,
      ManualActionRequired('x'): 9,
      ExternalToolException('x'): 10,
      RequestTimeoutException('x'): 5,
      SessionRequestException('x'): 4,
    };
    for (final entry in errors.entries) {
      final r = FlutterRunRunner(wiring: t.wiring, flushOutput: () async {})
        ..addCommand(_ThrowingCommand(entry.key));
      expect(await r.execute(['boom']), entry.value, reason: '${entry.key}');
    }
  });

  test('an unexpected error shows no stack trace without --verbose', () async {
    runner.addCommand(_ThrowingCommand(StateError('kaput')));
    expect(await runner.execute(['boom']), ExitCodes.internal);
    final text = t.console.errLines.join('\n');
    expect(text, contains('error: unexpected failure: Bad state: kaput'));
    expect(text, contains('Run with --verbose for details.'));
    expect(text, isNot(contains('#0')));
  });

  test('an unexpected error shows the stack trace with --verbose', () async {
    runner.addCommand(_ThrowingCommand(StateError('kaput')));
    expect(await runner.execute(['--verbose', 'boom'], verbose: true), 1);
    final text = t.console.errLines.join('\n');
    expect(text, contains('#0'));
    expect(text, isNot(contains('Run with --verbose')));
  });

  test('verboseRequested sees -v and --verbose but not after --', () {
    expect(verboseRequested(['-v', 'doctor']), isTrue);
    expect(verboseRequested(['doctor', '--verbose']), isTrue);
    expect(verboseRequested(['doctor']), isFalse);
    expect(verboseRequested(['doctor', '--', '-v']), isFalse);
  });

  group('global options', () {
    test('no command declares a global option twice', () {
      for (final option in ['--verbose', '--project', '--flutter-sdk']) {
        expect(
          RegExp(RegExp.escape(option)).allMatches(runner.argParser.usage),
          hasLength(1),
          reason: 'runner $option',
        );
        for (final command in runner.commands.values.where(
          (c) => c.name != 'help',
        )) {
          expect(
            RegExp(RegExp.escape(option)).allMatches(command.usage),
            hasLength(1),
            reason: '${command.name} $option',
          );
        }
      }
    });

    test('every planned command is registered', () {
      expect(
        runner.commands.keys,
        containsAll([
          'dap',
          'reload',
          'restart',
          'status',
          'devices',
          'select-device',
          'emulators',
          'devtools',
          'init',
          'doctor',
          'version',
        ]),
      );
    });

    test('the dap command parses the exact argv the Zed extension passes', () {
      final command = runner.commands['dap']!;
      final results = command.argParser.parse([
        '--cwd',
        '/my proj',
        '--kind',
        'flutter',
        '--request',
        'attach',
        '--flutter-sdk',
        '/sdk',
        '--use-fvm',
        '--log-file',
        '/tmp/l.log',
        '--client-version',
        '0.1.0',
      ]);
      expect(results['cwd'], '/my proj');
      expect(results['request'], 'attach');
      expect(results['flutter-sdk'], '/sdk');
      expect(results['use-fvm'], isTrue);
      expect(results['log-file'], '/tmp/l.log');
      expect(results['client-version'], '0.1.0');
    });

    test('dap rejects an unknown kind or request', () {
      final command = runner.commands['dap']!;
      expect(
        () => command.argParser.parse(['--kind', 'rust']),
        throwsFormatException,
      );
      expect(
        () => command.argParser.parse(['--request', 'run']),
        throwsFormatException,
      );
    });
  });

  test('R16: only the command word decides whether Ctrl+C is handled', () {
    expect(FlutterRunRunner.isDapCommand(['dap', '--cwd', '/x']), isTrue);
    expect(FlutterRunRunner.isDapCommand(['--verbose', 'dap']), isTrue);
    expect(
      FlutterRunRunner.isDapCommand(['devices', '--project', 'dap']),
      isFalse,
    );
    expect(
      FlutterRunRunner.isDapCommand(['--project', 'dap', 'reload']),
      isFalse,
    );
    expect(FlutterRunRunner.isDapCommand(const []), isFalse);
  });
}
