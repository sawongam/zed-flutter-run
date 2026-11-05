import 'dart:async';
import 'dart:io';

import 'package:flutter_run/src/cli/wiring.dart';
import 'package:flutter_run/src/common/errors.dart';
import 'package:flutter_run/src/common/json_types.dart';
import 'package:flutter_run/src/control/control_protocol.dart';
import 'package:flutter_run/src/control/control_server.dart';
import 'package:flutter_run/src/control/session_info.dart';
import 'package:flutter_run/src/dap/hot_actions.dart';
import 'package:flutter_run/src/dap/messages.dart';
import 'package:flutter_run/src/dap/notices.dart';
import 'package:test/test.dart';

import '../sdk/fake_sdk.dart';
import 'support.dart';

class _FakeInjector implements RequestInjector {
  _FakeInjector({this.started = true});

  bool started;
  Completer<DapJson>? hold;
  DapJson Function(String command) respond = (command) => {'success': true};
  final List<String> commands = [];

  @override
  bool get appStarted => started;

  @override
  Future<DapJson> inject(
    String command, [
    Json? arguments,
    Duration? timeout,
  ]) async {
    commands.add(command);
    final pending = hold;
    if (pending != null) return pending.future;
    return respond(command);
  }

  @override
  void notice(String text, [NoticeLevel level = NoticeLevel.info]) {}
}

Future<ControlException> _controlError(Future<Json> call) async {
  try {
    await call;
  } on ControlException catch (e) {
    return e;
  }
  throw StateError('expected a ControlException');
}

void main() {
  group('ProxySessionControl', () {
    test('ping reports pid, version and protocol', () {
      final control = ProxySessionControl(HotActions(_FakeInjector()), pid: 42);
      expect(control.ping(), {'pid': 42, 'version': '0.1.0', 'protocol': 1});
    });

    test('reload and restart return durations', () async {
      final injector = _FakeInjector();
      final control = ProxySessionControl(HotActions(injector));
      final reload = await control.reload({'reason': 'manual'});
      expect(reload, containsPair('coalesced', false));
      expect(reload['durationMs'], isA<int>());
      final restart = await control.restart({});
      expect(restart['durationMs'], isA<int>());
      expect(injector.commands, ['hotReload', 'hotRestart']);
    });

    test('app not started maps to app_not_started', () async {
      final control = ProxySessionControl(
        HotActions(_FakeInjector(started: false)),
      );
      final e = await _controlError(control.reload({}));
      expect(e.code, ControlErrorCode.appNotStarted);
    });

    test('an adapter failure maps to adapter_error with its message', () async {
      final injector = _FakeInjector()
        ..respond = (_) => {'success': false, 'message': 'Compile error'};
      final control = ProxySessionControl(HotActions(injector));
      final e = await _controlError(control.reload({}));
      expect(e.code, ControlErrorCode.adapterError);
      expect(e.message, contains('Compile error'));
    });

    test('a manual reload during a restart maps to busy', () async {
      final injector = _FakeInjector()..hold = Completer<DapJson>();
      final control = ProxySessionControl(HotActions(injector));
      final restart = control.restart({});
      await Future<void>.delayed(Duration.zero);
      final e = await _controlError(control.reload({}));
      expect(e.code, ControlErrorCode.busy);
      injector.hold!.complete({'success': true});
      await restart;
    });

    test('a timeout maps to timeout', () async {
      final injector = _FakeInjector()
        ..respond = (_) => throw TimeoutException('late');
      final control = ProxySessionControl(HotActions(injector));
      final e = await _controlError(control.reload({}));
      expect(e.code, ControlErrorCode.timeout);
    });

    test('a closed session maps to session_ended', () async {
      final injector = _FakeInjector()
        ..respond = (_) => throw StateError('closed');
      final control = ProxySessionControl(HotActions(injector));
      final e = await _controlError(control.restart({}));
      expect(e.code, ControlErrorCode.sessionEnded);
    });

    test(
      'after markEnding every action is refused with session_ended',
      () async {
        final injector = _FakeInjector();
        final control = ProxySessionControl(HotActions(injector))..markEnding();
        expect(
          (await _controlError(control.reload({}))).code,
          ControlErrorCode.sessionEnded,
        );
        expect(injector.commands, isEmpty);
      },
    );
  });

  group('reloadForSave', () {
    test('maps a busy result to busy: true', () async {
      final injector = _FakeInjector()..hold = Completer<DapJson>();
      final hot = HotActions(injector);
      final restart = hot.restart();
      await Future<void>.delayed(Duration.zero);
      // A save during a restart waits for it, so release the restart first.
      final save = reloadForSave(hot);
      injector.hold!.complete({'success': true});
      await restart;
      injector.hold = null;
      final outcome = await save;
      expect(outcome.ok, isTrue);
      expect(outcome.busy, isFalse);
    });

    test('a join of a running reload reports joined', () async {
      final injector = _FakeInjector()..hold = Completer<DapJson>();
      final hot = HotActions(injector);
      final manual = hot.reload();
      await Future<void>.delayed(Duration.zero);
      final save = reloadForSave(hot);
      injector.hold!.complete({'success': true});
      await manual;
      final outcome = await save;
      expect(outcome.ok, isTrue);
      expect(outcome.joined, isTrue);
    });

    test('a timeout is not a failure for the watcher', () async {
      final injector = _FakeInjector()
        ..respond = (_) => throw TimeoutException('pending');
      final outcome = await reloadForSave(HotActions(injector));
      expect(outcome.ok, isFalse);
      expect(outcome.busy, isTrue);
    });

    test('reports a failure message', () async {
      final injector = _FakeInjector()
        ..respond = (_) => {'success': false, 'message': 'nope'};
      final outcome = await reloadForSave(HotActions(injector));
      expect(outcome.ok, isFalse);
      expect(outcome.message, contains('nope'));
    });
  });

  group('flutterRunnerFactory', () {
    late TestWiring t;
    setUp(() => t = TestWiring());
    tearDown(() => t.dispose());

    String sdkWithScript(String script) {
      final sdk = makeFakeSdk('${t.dir.path}/sdk');
      File('$sdk/bin/flutter').writeAsStringSync('#!/bin/sh\n$script\n');
      return sdk;
    }

    test('runs the resolved flutter and returns its output', () async {
      final sdk = sdkWithScript('echo "args: \$@"');
      final run = await t.wiring.flutterRunnerFactory(
        projectDir: t.dir.path,
        explicitSdk: sdk,
      );
      final result = await run(['devices', '--machine']);
      expect(result.exitCode, 0);
      expect(result.stdout.trim(), 'args: devices --machine');
    }, skip: Platform.isWindows ? 'needs a shell script' : false);

    test('translates a timeout into a TimeoutException', () async {
      final sdk = sdkWithScript('sleep 30');
      final run = await t.wiring.flutterRunnerFactory(
        projectDir: t.dir.path,
        explicitSdk: sdk,
      );
      await expectLater(
        run(['devices'], timeout: const Duration(milliseconds: 300)),
        throwsA(isA<TimeoutException>()),
      );
    }, skip: Platform.isWindows ? 'needs a shell script' : false);

    test('keeps a spawn failure an ExternalToolException', () async {
      final sdk = makeFakeSdk('${t.dir.path}/sdk');
      File(
        '$sdk/bin/flutter',
      ).writeAsStringSync('#!/nonexistent/interpreter\n');
      final run = await t.wiring.flutterRunnerFactory(
        projectDir: t.dir.path,
        explicitSdk: sdk,
      );
      await expectLater(
        run(['devices']),
        throwsA(isA<ExternalToolException>()),
      );
    }, skip: Platform.isWindows ? 'needs a shell script' : false);

    test('an unresolvable SDK throws SdkNotFoundException', () async {
      await expectLater(
        t.wiring.flutterRunnerFactory(projectDir: t.dir.path),
        throwsA(isA<SdkNotFoundException>()),
      );
    });
  });

  group('vmServiceTargetResolver', () {
    late TestWiring t;
    late ControlServer server;
    setUp(() async {
      t = TestWiring();
      server = await ControlServer.start(
        control: ProxySessionControl(HotActions(_FakeInjector())),
      );
    });
    tearDown(() async {
      await server.close();
      t.dispose();
    });

    Future<void> addSession(int pid, {String? uri, DateTime? at}) async {
      Directory('${t.dir.path}/app').createSync();
      File('${t.dir.path}/app/pubspec.yaml').writeAsStringSync('name: app\n');
      await t.wiring.sessionStore.create(
        SessionInfo(
          pid: pid,
          port: server.port,
          token: server.token,
          projectRoot: '${t.dir.path}/app',
          cwd: '${t.dir.path}/app',
          kind: 'flutter',
          request: 'launch',
          startedAt: at ?? DateTime.now().toUtc(),
          vmServiceUri: uri,
        ),
      );
    }

    test('no session is exit 3', () async {
      await expectLater(
        t.wiring.vmServiceTargetResolver(directory: '${t.dir.path}/app'),
        throwsA(isA<NoSessionException>()),
      );
    });

    test('a session without an address is exit 4', () async {
      await addSession(900001);
      await expectLater(
        t.wiring.vmServiceTargetResolver(directory: '${t.dir.path}/app'),
        throwsA(
          isA<SessionRequestException>().having(
            (e) => e.message,
            'message',
            contains('still starting'),
          ),
        ),
      );
    });

    test('picks the most recent session that has an address', () async {
      final now = DateTime.now().toUtc();
      await addSession(
        900002,
        uri: 'ws://127.0.0.1:1/old=/ws',
        at: now.subtract(const Duration(minutes: 5)),
      );
      await addSession(900003, uri: 'ws://127.0.0.1:2/new=/ws', at: now);
      final target = await t.wiring.vmServiceTargetResolver(
        directory: '${t.dir.path}/app',
      );
      expect(target.vmServiceUri, 'ws://127.0.0.1:2/new=/ws');
      expect(target.sessionPid, 900003);
      expect(target.kind, 'flutter');
    });
  });
}
