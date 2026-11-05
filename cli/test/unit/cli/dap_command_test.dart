import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_run/src/cli/dap_command.dart';
import 'package:flutter_run/src/common/errors.dart';
import 'package:flutter_run/src/dap/framing.dart';
import 'package:flutter_run/src/dap/messages.dart';
import 'package:test/test.dart';

import '../dap/fakes.dart';
import '../sdk/fake_sdk.dart';
import 'support.dart';

/// Drives `DapCommand` through in-memory stdio like Zed does.
class Client {
  Client() {
    _outputController.stream.listen((chunk) {
      for (final message in _decoder.add(chunk)) {
        messages.add(message);
        for (final w in _waiters.toList()) {
          w();
        }
      }
    });
  }

  final StreamController<List<int>> input = StreamController<List<int>>();
  final StreamController<List<int>> _outputController =
      StreamController<List<int>>();
  final DapFrameDecoder _decoder = DapFrameDecoder();
  final List<DapJson> messages = [];
  final List<void Function()> _waiters = [];
  int _seq = 1;

  StreamSink<List<int>> get output => _outputController.sink;

  int send(String command, [Map<String, Object?>? arguments]) {
    final seq = _seq++;
    input.add(
      encodeDapMessage({
        'seq': seq,
        'type': 'request',
        'command': command,
        'arguments': ?arguments,
      }),
    );
    return seq;
  }

  Future<DapJson> waitFor(
    bool Function(DapJson) test, {
    Duration timeout = const Duration(seconds: 30),
    String what = 'a message',
  }) {
    final done = Completer<DapJson>();
    void check() {
      if (done.isCompleted) return;
      for (final m in messages) {
        if (test(m)) {
          done.complete(m);
          return;
        }
      }
    }

    _waiters.add(check);
    check();
    return done.future.timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        'Timed out waiting for $what. Got: ${jsonEncode(messages)}',
      ),
    );
  }

  Future<DapJson> response(int seq) => waitFor(
    (m) => m['type'] == 'response' && m['request_seq'] == seq,
    what: 'the response to request $seq',
  );

  Future<DapJson> output_(String contains) => waitFor(
    (m) =>
        m['event'] == 'output' &&
        ((m['body'] as Map)['output'] as String).contains(contains),
    what: 'output containing "$contains"',
  );

  Iterable<String> get outputs => [
    for (final m in messages)
      if (m['event'] == 'output') (m['body'] as Map)['output'] as String,
  ];
}

/// Writes a `flutter` launcher into the fake SDK that runs the fake adapter
/// with [env] set (a `.bat` on Windows, a `/bin/sh` script elsewhere).
void writeShim(
  String sdk, {
  String? argsFile,
  Map<String, String> env = const {},
}) {
  final adapter = '${Directory.current.path}/test/unit/cli/fake_adapter.dart';
  final dart = Platform.resolvedExecutable;
  if (Platform.isWindows) {
    File('$sdk/bin/flutter.bat').writeAsStringSync(
      '@echo off\r\n'
      '${argsFile == null ? '' : 'echo %* > "$argsFile"\r\n'}'
      '${env.entries.map((e) => 'set ${e.key}=${e.value}\r\n').join()}'
      '"$dart" "$adapter" %*\r\n',
    );
  } else {
    File('$sdk/bin/flutter').writeAsStringSync(
      '#!/bin/sh\n'
      '${argsFile == null ? '' : 'echo "\$@" > "$argsFile"\n'}'
      '${env.entries.map((e) => 'export ${e.key}="${e.value}"\n').join()}'
      'exec "$dart" "$adapter" "\$@"\n',
    );
  }
}

void main() {
  late TestWiring t;
  late Client client;
  late String sdk;
  late String record;

  setUp(() {
    t = TestWiring();
    client = Client();
    sdk = makeFakeSdk('${t.dir.path}/sdk');
    record = '${t.dir.path}/record.json';
    writeShim(
      sdk,
      argsFile: '${t.dir.path}/args.txt',
      env: {'FAKE_ADAPTER_RECORD': record},
    );
    Directory('${t.dir.path}/app/lib').createSync(recursive: true);
    File('${t.dir.path}/app/pubspec.yaml').writeAsStringSync('name: app\n');
  });

  tearDown(() => t.dispose());

  CommandRunner<int> runnerWith(DapCommand command) =>
      CommandRunner<int>('flutter_run', 'test')..addCommand(command);

  Future<int?> runDap(List<String> args, {Duration? watchdog}) {
    final command = DapCommand(
      t.wiring,
      input: client.input.stream,
      output: client.output,
      resolvedExecutable: '/opt/tools/flutter_run',
      attachWatchdog: watchdog ?? const Duration(seconds: 15),
      startupResponseWait: const Duration(milliseconds: 500),
      sessionWriteDebounce: const Duration(milliseconds: 10),
    );
    return runnerWith(command).run([
      'dap',
      '--cwd',
      '${t.dir.path}/app',
      '--flutter-sdk',
      sdk,
      '--client-version',
      '0.9.0',
      ...args,
    ]);
  }

  Directory sessions() => Directory('${t.dir.path}/state/sessions');

  List<File> sessionFiles() => sessions().existsSync()
      ? sessions()
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList()
      : <File>[];

  Future<Map<String, Object?>> waitForSession(
    bool Function(Map<String, Object?>) test,
  ) async {
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(end)) {
      for (final f in sessionFiles()) {
        try {
          final json = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
          if (test(json)) return json;
        } on FormatException {
          // Being replaced; try again.
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw TimeoutException('No matching session file. Files: $sessionFiles');
  }

  group('startup failure responder', () {
    test('SDK not found: failed response, stderr output, exit 6', () async {
      final command = DapCommand(
        t.wiring,
        input: client.input.stream,
        output: client.output,
        startupResponseWait: const Duration(seconds: 5),
      );
      final exit = runnerWith(
        command,
      ).run(['dap', '--cwd', '${t.dir.path}/app']);
      final seq = client.send('initialize', {'adapterID': 'FlutterRun'});
      final response = await client.response(seq);
      expect(response['success'], isFalse);
      expect(response['command'], 'initialize');
      expect(response['message'], contains('Could not find a Flutter SDK'));
      expect(response['message'], contains('FLUTTER_RUN_FLUTTER_SDK'));
      final out = await client.waitFor(
        (m) =>
            m['event'] == 'output' &&
            (m['body'] as Map)['category'] == 'stderr',
      );
      expect((out['body'] as Map)['output'], contains('Error: Could not find'));
      expect(await exit, ExitCodes.sdkNotFound);
    });

    test('an invalid explicit SDK path is also reported (exit 6)', () async {
      final command = DapCommand(
        t.wiring,
        input: client.input.stream,
        output: client.output,
        startupResponseWait: const Duration(seconds: 5),
      );
      final exit = runnerWith(command).run([
        'dap',
        '--cwd',
        '${t.dir.path}/app',
        '--flutter-sdk',
        '${t.dir.path}/nothing-here',
      ]);
      client.send('initialize');
      final out = await client.output_('does not contain');
      expect(out, isNotNull);
      expect(await exit, ExitCodes.sdkNotFound);
    });

    test(
      'without any request it still writes the console text and exits',
      () async {
        final command = DapCommand(
          t.wiring,
          input: client.input.stream,
          output: client.output,
          startupResponseWait: const Duration(milliseconds: 100),
        );
        final exit = await runnerWith(
          command,
        ).run(['dap', '--cwd', '${t.dir.path}/app']);
        expect(exit, ExitCodes.sdkNotFound);
        expect(client.messages.where((m) => m['type'] == 'response'), isEmpty);
        await client.output_('Could not find a Flutter SDK');
      },
    );

    test(
      'a spawn failure answers with exit 1',
      () async {
        File(
          '$sdk/bin/flutter',
        ).writeAsStringSync('#!/nonexistent/interpreter\n');
        final exit = runDap([]);
        client.send('initialize');
        final out = await client.output_('Could not start');
        expect(out, isNotNull);
        expect(await exit, 1);
      },
      skip: Platform.isWindows
          ? 'a missing script interpreter is POSIX-specific'
          : null,
    );

    test(
      'answerStartupFailure answers the first request, not later ones',
      () async {
        final channel = FakeChannel();
        final done = answerStartupFailure(
          channel,
          'Broken.',
          wait: const Duration(seconds: 5),
        );
        channel.incoming
          ..add({'seq': 4, 'type': 'request', 'command': 'initialize'})
          ..add({'seq': 5, 'type': 'request', 'command': 'launch'});
        await done;
        final responses = channel.sentWhere('response').toList();
        expect(responses, hasLength(1));
        expect(responses.single['request_seq'], 4);
        expect(responses.single['success'], isFalse);
        expect(responses.single['seq'], 1000000000);
        final event = channel.sentWhere('event', 'output').single;
        expect((event['body'] as Map)['category'], 'stderr');
        expect(channel.closed, isTrue);
      },
    );
  });

  group('signals (R3)', () {
    for (final signal in [
      ProcessSignal.sigint,
      if (!Platform.isWindows) ProcessSignal.sigterm,
      if (!Platform.isWindows) ProcessSignal.sighup,
    ]) {
      test('${signal.name} runs the same cleanup as a closed stdin', () async {
        final controllers = {
          for (final s in [
            ProcessSignal.sigint,
            ProcessSignal.sigterm,
            ProcessSignal.sighup,
          ])
            s: StreamController<ProcessSignal>.broadcast(),
        };
        final command = DapCommand(
          t.wiring,
          input: client.input.stream,
          output: client.output,
          resolvedExecutable: '/opt/tools/flutter_run',
          startupResponseWait: const Duration(milliseconds: 500),
          sessionWriteDebounce: const Duration(milliseconds: 10),
          signalSource: (s) =>
              (controllers[s] ?? StreamController<ProcessSignal>()).stream,
        );
        final exit = runnerWith(
          command,
        ).run(['dap', '--cwd', '${t.dir.path}/app', '--flutter-sdk', sdk]);
        client.send('initialize');
        client.send('launch', {'cwd': '${t.dir.path}/app', 'noDebug': true});
        await waitForSession((s) => s['appStarted'] == true);
        controllers[signal]!.add(signal);
        expect(await exit.timeout(const Duration(seconds: 30)), 0);
        expect(sessionFiles(), isEmpty);
      });
    }
  });

  group('a session', () {
    test(
      'launch: notices, session file, terminate hold and clean exit',
      () async {
        final exit = runDap([]);
        final init = client.send('initialize', {'adapterID': 'FlutterRun'});
        expect((await client.response(init))['success'], isTrue);

        final launch = client.send('launch', {
          'program': 'lib/main.dart',
          'cwd': '${t.dir.path}/app',
          'reloadOnSave': 'changed',
          'openDevTools': 'never',
          'noDebug': true,
        });
        expect((await client.response(launch))['success'], isTrue);

        // Start notices: version mismatch, PATH, device source.
        await client.output_('The Zed extension is version 0.9.0');
        await client.output_(
          'Warning: the flutter_run command is not on your PATH',
        );
        await client.output_('using /opt/tools/flutter_run.');
        await client.output_('No device was chosen');
        await client.output_('Reload on save is on for lib/');

        final session = await waitForSession((s) => s['appStarted'] == true);
        expect(session['kind'], 'flutter');
        expect(session['request'], 'launch');
        expect(session['deviceId'], 'fake-device');
        expect(session['mode'], 'debug');
        expect(session['vmServiceUri'], 'ws://127.0.0.1:9/abc=/ws');
        expect(
          session['projectRoot'],
          endsWith('${Platform.pathSeparator}app'),
        );
        expect(session['pid'], pid);

        // Own keys never reach the adapter.
        final sent = jsonDecode(File(record).readAsStringSync()) as Map;
        expect(sent.containsKey('reloadOnSave'), isFalse);
        expect(sent.containsKey('openDevTools'), isFalse);
        expect(sent['noDebug'], isTrue);
        expect(
          File('${t.dir.path}/args.txt').readAsStringSync().trim(),
          'debug_adapter',
        );

        // Zed's stop: terminate, then the session file is gone before the
        // response is relayed.
        final terminate = client.send('terminate');
        final response = await client.response(terminate);
        expect(response['success'], isTrue);
        expect(sessionFiles(), isEmpty);
        client.input.add(const []);
        await client.input.close();
        expect(await exit, 0);
      },
    );

    test('attach: --no-dds and the 15 s watchdog notice', () async {
      writeShim(
        sdk,
        argsFile: '${t.dir.path}/args.txt',
        env: {'FAKE_ADAPTER_STALL': '1', 'FAKE_ADAPTER_RECORD': record},
      );
      final exit = runDap([
        '--request',
        'attach',
      ], watchdog: const Duration(milliseconds: 300));
      client.send('initialize');
      client.send('attach', {'cwd': '${t.dir.path}/app'});
      await client.output_(
        'Still waiting for the app. Start it with "flutter run"',
      );
      expect(
        File('${t.dir.path}/args.txt').readAsStringSync().trim(),
        'debug_adapter --no-dds',
      );
      final session = await waitForSession((s) => s['request'] == 'attach');
      expect(session['appStarted'], isFalse);
      final terminate = client.send('terminate');
      await client.response(terminate);
      await client.input.close();
      expect(await exit, 0);
    });

    test('profile mode switches reload on save off with a notice', () async {
      writeShim(sdk, env: {'FAKE_ADAPTER_MODE': 'profile'});
      final exit = runDap([]);
      client.send('initialize');
      client.send('launch', {'cwd': '${t.dir.path}/app', 'deviceId': 'x'});
      await client.output_(
        'Reload on save is off because the app runs in profile mode',
      );
      expect(
        client.outputs.where((o) => o.contains('No device was chosen')),
        isEmpty,
      );
      final terminate = client.send('terminate');
      await client.response(terminate);
      await client.input.close();
      expect(await exit, 0);
    });
  });
}
