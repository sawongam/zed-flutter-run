import 'dart:async';
import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_run/src/common/console.dart';
import 'package:flutter_run/src/common/errors.dart';
import 'package:flutter_run/src/common/global_options.dart';
import 'package:flutter_run/src/common/host_environment.dart';
import 'package:flutter_run/src/common/json_types.dart';
import 'package:flutter_run/src/control/control_client.dart';
import 'package:flutter_run/src/control/control_protocol.dart';
import 'package:flutter_run/src/control/reload_command.dart';
import 'package:flutter_run/src/control/restart_command.dart';
import 'package:flutter_run/src/control/session_info.dart';
import 'package:flutter_run/src/control/session_store.dart';
import 'package:flutter_run/src/control/status_command.dart';
import 'package:test/test.dart';

import 'support.dart';

class FakeStore extends SessionStore {
  FakeStore(super.env, this.records);
  final List<SessionRecord> records;

  @override
  Future<List<SessionRecord>> list({bool prune = true}) async => records;
}

typedef Reply = FutureOr<ControlResponse> Function(SessionInfo, String, Json);

class FakeClient extends ControlClient {
  FakeClient(this.reply);
  final Reply reply;
  final List<(int, String, Json, Duration)> sent = [];

  @override
  Future<ControlResponse> send(
    SessionInfo session,
    String command, {
    Json args = const {},
    Duration timeout = const Duration(seconds: 120),
  }) async {
    sent.add((session.pid, command, args, timeout));
    return reply(session, command, args);
  }
}

ControlResponse okReply([int ms = 593, bool coalesced = false]) =>
    ControlResponse(
      ok: true,
      result: {'durationMs': ms, 'coalesced': coalesced},
    );

SessionRecord record(
  int pid, {
  String root = '/work/app',
  String kind = 'flutter',
  bool started = true,
  bool unresponsive = false,
  String? device = 'linux',
}) => SessionRecord(
  info: sessionInfo(
    pid: pid,
    projectRoot: root,
    kind: kind,
    appStarted: started,
    deviceId: device,
    startedAt: DateTime.utc(2026, 1, 1, 0, pid),
  ),
  unresponsive: unresponsive,
  path: '/state/sessions/$pid.json',
);

class Harness {
  Harness(this.records, this.client, {HostEnvironment? environment})
    : env = environment ?? linuxEnv(),
      console = MemoryConsole() {
    final store = FakeStore(env, records);
    runner = CommandRunner<int>('flutter_run', 'test');
    GlobalOptions.addTo(runner.argParser);
    runner
      ..addCommand(
        ReloadCommand(store: store, client: client, env: env, console: console),
      )
      ..addCommand(
        RestartCommand(
          store: store,
          client: client,
          env: env,
          console: console,
        ),
      )
      ..addCommand(StatusCommand(store: store, env: env, console: console));
  }

  final List<SessionRecord> records;
  final FakeClient client;
  final HostEnvironment env;
  final MemoryConsole console;
  late final CommandRunner<int> runner;

  Future<int?> run(List<String> args) => runner.run(args);
}

List<String> waiting(Harness h) =>
    h.console.errLines.where((l) => l.startsWith('Waiting...')).toList();

void main() {
  group('reload', () {
    test('no matching session: exit 3 with the documented text', () async {
      final h = Harness([
        record(1, root: '/other'),
      ], FakeClient((_, _, _) => okReply()));
      await expectLater(
        h.run(['reload']),
        throwsA(
          isA<NoSessionException>()
              .having((e) => e.exitCode, 'exitCode', 3)
              .having(
                (e) => e.message,
                'message',
                'No running Flutter app found for /work/app.',
              )
              .having(
                (e) => e.hint,
                'hint',
                allOf(
                  contains('F4'),
                  contains('"Dart" adapter'),
                  contains('"FlutterRun"'),
                ),
              ),
        ),
      );
      expect(h.client.sent, isEmpty);
    });

    test('no sessions at all: exit 3', () async {
      final h = Harness([], FakeClient((_, _, _) => okReply()));
      await expectLater(h.run(['reload']), throwsA(isA<NoSessionException>()));
    });

    test('one session: result line, args, exit 0', () async {
      final h = Harness([record(1)], FakeClient((_, _, _) => okReply()));
      expect(await h.run(['reload']), 0);
      expect(h.console.outLines, ['Hot reload: linux app ok in 0.6 s']);
      expect(h.console.errLines, isEmpty);
      expect(h.client.sent.single.$2, 'reload');
      expect(h.client.sent.single.$3, {'reason': 'manual'});
      expect(h.client.sent.single.$4, const Duration(seconds: 120));
    });

    test('coalesced reload says so', () async {
      final h = Harness([
        record(1),
      ], FakeClient((_, _, _) => okReply(1200, true)));
      expect(await h.run(['reload']), 0);
      expect(
        h.console.outLines.single,
        startsWith('Hot reload: linux app ok in 1.2 s'),
      );
      expect(h.console.outLines.single, contains('already running'));
    });

    test('--timeout and --project are honoured', () async {
      final h = Harness([
        record(1, root: '/w/one'),
        record(2, root: '/w/two'),
      ], FakeClient((_, _, _) => okReply()));
      expect(
        await h.run(['reload', '--timeout', '7', '--project', '/w/two']),
        0,
      );
      expect(h.client.sent.map((s) => s.$1), [2]);
      expect(h.client.sent.single.$4, const Duration(seconds: 7));
    });

    test('bad --timeout is a usage error', () async {
      final h = Harness([record(1)], FakeClient((_, _, _) => okReply()));
      for (final value in ['0', '-1', 'abc', '1.5']) {
        await expectLater(
          h.run(['reload', '--timeout', value]),
          throwsA(isA<UsageError>()),
          reason: value,
        );
      }
    });

    test('two Flutter sessions are both reloaded, one line each', () async {
      final h = Harness([
        record(1, device: 'linux'),
        record(2, root: '/work/app/example', device: 'chrome'),
      ], FakeClient((_, _, _) => okReply()));
      expect(await h.run(['reload']), 0);
      expect(h.client.sent.map((s) => s.$1), unorderedEquals([1, 2]));
      expect(h.console.outLines, [
        'Hot reload: linux app ok in 0.6 s',
        'Hot reload: chrome example ok in 0.6 s',
      ]);
    });

    test('parent directory notes that every app below is included', () async {
      final h = Harness(
        [record(1, root: '/work/app')],
        FakeClient((_, _, _) => okReply()),
        environment: linuxEnv(cwd: '/work'),
      );
      expect(await h.run(['reload']), 0);
      expect(h.console.errLines.single, contains('every running app below it'));
    });

    test('one failing: exit 4, the other is still reported', () async {
      final h = Harness(
        [
          record(1, device: 'linux'),
          record(2, root: '/work/app/ex', device: 'chrome'),
        ],
        FakeClient(
          (s, _, _) => s.pid == 1
              ? okReply()
              : const ControlResponse(
                  ok: false,
                  errorCode: ControlErrorCode.adapterError,
                  errorMessage: 'Reload rejected: syntax error.',
                ),
        ),
      );
      expect(await h.run(['reload']), 4);
      expect(h.console.outLines, [
        'Hot reload: linux app ok in 0.6 s',
        'Hot reload: chrome ex failed: Reload rejected: syntax error.',
      ]);
    });

    test('server errors map to plain sentences', () async {
      for (final (code, text) in [
        (ControlErrorCode.busy, 'another reload or restart is still running.'),
        (ControlErrorCode.appNotStarted, 'the app is still starting.'),
        (ControlErrorCode.sessionEnded, 'the debug session has ended.'),
      ]) {
        final h = Harness(
          [record(1)],
          FakeClient(
            (_, _, _) =>
                ControlResponse(ok: false, errorCode: code, errorMessage: 'x'),
          ),
        );
        expect(await h.run(['reload']), 4);
        expect(
          h.console.outLines.single,
          'Hot reload: linux app failed: $text',
        );
      }
    });

    test('server-side timeout code and client timeout give exit 5', () async {
      final a = Harness(
        [record(1)],
        FakeClient(
          (_, _, _) => const ControlResponse(
            ok: false,
            errorCode: ControlErrorCode.timeout,
            errorMessage: 'The adapter did not answer.',
          ),
        ),
      );
      expect(await a.run(['reload']), 5);
      final b = Harness(
        [record(1)],
        FakeClient(
          (_, _, _) => throw const ControlClientException(
            ControlClientFailure.timeout,
            'late',
          ),
        ),
      );
      expect(await b.run(['reload', '--timeout', '3']), 5);
      expect(
        b.console.outLines.single,
        contains('failed: no answer within 3 s.'),
      );
    });

    test('unreachable session while acting is a failure (exit 4)', () async {
      final h = Harness(
        [record(1)],
        FakeClient(
          (_, _, _) => throw const ControlClientException(
            ControlClientFailure.unreachable,
            'refused',
          ),
        ),
      );
      expect(await h.run(['reload']), 4);
      expect(h.console.outLines.single, contains('failed:'));
    });

    test(
      'timeout wins over another failure, success is still printed',
      () async {
        final h = Harness(
          [
            record(1),
            record(2, root: '/work/app/b'),
            record(3, root: '/work/app/c'),
          ],
          FakeClient((s, _, _) {
            if (s.pid == 1) return okReply();
            if (s.pid == 2) {
              throw const ControlClientException(
                ControlClientFailure.timeout,
                't',
              );
            }
            return const ControlResponse(
              ok: false,
              errorCode: ControlErrorCode.adapterError,
              errorMessage: 'boom',
            );
          }),
        );
        expect(await h.run(['reload']), 5);
        expect(h.console.outLines, hasLength(3));
      },
    );

    test(
      'Dart-kind session is skipped with a note; the Flutter one runs',
      () async {
        final h = Harness([
          record(1, kind: 'dart'),
          record(2, root: '/work/app/b'),
        ], FakeClient((_, _, _) => okReply()));
        expect(await h.run(['reload']), 0);
        expect(h.client.sent.map((s) => s.$1), [2]);
        expect(
          h.console.errLines,
          contains(
            'Skipped pid 1: it is a Dart console session, not a Flutter app.',
          ),
        );
      },
    );

    test(
      'unresponsive session is skipped with a hint and does not block others',
      () async {
        final h = Harness([
          record(1, unresponsive: true),
          record(2, root: '/work/app/b'),
        ], FakeClient((_, _, _) => okReply()));
        expect(await h.run(['reload']), 0);
        expect(h.client.sent.map((s) => s.$1), [2]);
        expect(
          h.console.errLines,
          contains(
            'Skipped pid 1: it did not answer. If Zed is hung, stop that debug session.',
          ),
        );
      },
    );

    test('not-started session is reported and skipped', () async {
      final h = Harness([
        record(1, started: false),
        record(2, root: '/work/app/b'),
      ], FakeClient((_, _, _) => okReply()));
      expect(await h.run(['reload']), 0);
      expect(h.client.sent.map((s) => s.$1), [2]);
      expect(h.console.errLines, contains('pid 1: the app is still starting.'));
    });

    test('all skipped: exit 4 and nothing is sent', () async {
      final h = Harness([
        record(1, started: false),
        record(2, kind: 'dart'),
        record(3, unresponsive: true),
      ], FakeClient((_, _, _) => okReply()));
      expect(await h.run(['reload']), 4);
      expect(h.client.sent, isEmpty);
      expect(h.console.errLines, hasLength(3));
      expect(h.console.outLines, isEmpty);
    });

    test('sessions are contacted concurrently', () {
      fakeAsync((async) {
        final h = Harness(
          [record(1), record(2, root: '/work/app/b')],
          FakeClient((_, _, _) async {
            await Future<void>.delayed(const Duration(seconds: 1));
            return okReply();
          }),
        );
        int? code;
        h.run(['reload']).then((c) => code = c);
        async.flushMicrotasks();
        expect(h.client.sent, hasLength(2));
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(code, 0);
      });
    });

    test(
      'waiting notice appears once after 3 s, not before, not for fast replies',
      () {
        fakeAsync((async) {
          final h = Harness(
            [record(1), record(2, root: '/work/app/b')],
            FakeClient((_, _, _) async {
              await Future<void>.delayed(const Duration(seconds: 10));
              return okReply();
            }),
          );
          int? code;
          h.run(['reload']).then((c) => code = c);
          async.flushMicrotasks();
          async.elapse(const Duration(milliseconds: 2999));
          expect(waiting(h), isEmpty);
          async.elapse(const Duration(milliseconds: 2));
          const notice =
              'Waiting... the app may be paused at a breakpoint (Ctrl+C to stop waiting).';
          expect(waiting(h), [notice]);
          async.elapse(const Duration(seconds: 10));
          async.flushMicrotasks();
          expect(code, 0);
          expect(waiting(h), [notice]);
          expect(h.console.outLines, hasLength(2));
        });
      },
    );

    test('no waiting notice when the reply is quick', () {
      fakeAsync((async) {
        final h = Harness([record(1)], FakeClient((_, _, _) => okReply()));
        h.run(['reload']);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 30));
        expect(h.console.errLines, isEmpty);
      });
    });

    test('the waiting delay is injectable', () {
      fakeAsync((async) {
        final console = MemoryConsole();
        final env = linuxEnv();
        final client = FakeClient((_, _, _) async {
          await Future<void>.delayed(const Duration(seconds: 2));
          return okReply();
        });
        final runner = CommandRunner<int>('flutter_run', 't')
          ..addCommand(
            ReloadCommand(
              store: FakeStore(env, [record(1)]),
              client: client,
              env: env,
              console: console,
              waitingNoticeAfter: const Duration(seconds: 1),
            ),
          );
        runner.run(['reload']);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1100));
        expect(console.errLines, hasLength(1));
      });
    });
  });

  group('restart', () {
    test('sends restart without args and prints Hot restart lines', () async {
      final h = Harness([record(1)], FakeClient((_, _, _) => okReply(320)));
      expect(await h.run(['restart']), 0);
      expect(h.client.sent.single.$2, 'restart');
      expect(h.client.sent.single.$3, isEmpty);
      expect(h.console.outLines, ['Hot restart: linux app ok in 0.3 s']);
    });

    test('failure, no session and unknown device name', () async {
      final fail = Harness(
        [record(1, device: null)],
        FakeClient(
          (_, _, _) => const ControlResponse(
            ok: false,
            errorCode: ControlErrorCode.adapterError,
            errorMessage: 'nope',
          ),
        ),
      );
      expect(await fail.run(['restart']), 4);
      expect(
        fail.console.outLines.single,
        'Hot restart: unknown device app failed: nope',
      );
      final none = Harness([], FakeClient((_, _, _) => okReply()));
      await expectLater(
        none.run(['restart']),
        throwsA(isA<NoSessionException>()),
      );
    });
  });

  group('status', () {
    test('no sessions', () async {
      final h = Harness([], FakeClient((_, _, _) => okReply()));
      expect(await h.run(['status']), 0);
      expect(
        h.console.outLines.single,
        startsWith('No running debug sessions.'),
      );
    });

    test('text marks matching sessions and states', () async {
      final h = Harness([
        record(1),
        record(2, root: '/elsewhere', started: false),
        record(3, root: '/work/app/b', unresponsive: true),
      ], FakeClient((_, _, _) => okReply()));
      expect(await h.run(['status']), 0);
      final lines = h.console.outLines;
      expect(lines[0], startsWith('* pid 1  flutter  linux  app  running'));
      expect(
        lines[1],
        startsWith('  pid 2  flutter  linux  elsewhere  starting'),
      );
      expect(lines[2], startsWith('* pid 3'));
      expect(lines[2], contains('not answering'));
    });

    test('--json shape never contains the token', () async {
      final h = Harness([
        record(1),
        record(2, root: '/elsewhere', kind: 'dart', unresponsive: true),
      ], FakeClient((_, _, _) => okReply()));
      expect(await h.run(['status', '--json']), 0);
      final text = h.console.outLines.join('\n');
      expect(text, isNot(contains('tok')));
      final json = jsonDecode(text) as Json;
      expect(json['directory'], '/work/app');
      final sessions = (json['sessions'] as List).cast<Json>();
      expect(sessions, hasLength(2));
      expect(sessions[0], {
        'pid': 1,
        'kind': 'flutter',
        'request': 'launch',
        'projectRoot': '/work/app',
        'cwd': '/work/app',
        'startedAt': '2026-01-01T00:01:00.000Z',
        'deviceId': 'linux',
        'mode': 'debug',
        'vmServiceUri': null,
        'appStarted': true,
        'unresponsive': false,
        'matches': true,
      });
      expect(sessions[1]['matches'], false);
      expect(sessions[1]['unresponsive'], true);
    });

    test('--project selects the directory to match', () async {
      final h = Harness([
        record(1),
        record(2, root: '/elsewhere'),
      ], FakeClient((_, _, _) => okReply()));
      await h.run(['status', '--json', '--project', '/elsewhere']);
      final json = jsonDecode(h.console.outLines.single) as Json;
      expect(
        [for (final s in (json['sessions'] as List).cast<Json>()) s['matches']],
        [false, true],
      );
    });
  });

  group('case-insensitive hosts', () {
    for (final os in [HostOs.windows, HostOs.macos]) {
      test('${os.name}: differing case still matches', () async {
        final isWin = os == HostOs.windows;
        final env = HostEnvironment(
          os: os,
          environment: const {},
          currentDirectory: isWin ? r'c:\work\app' : '/work/app',
        );
        final h = Harness(
          [record(1, root: isWin ? r'C:\Work\App' : '/Work/App')],
          FakeClient((_, _, _) => okReply()),
          environment: env,
        );
        expect(await h.run(['reload']), 0);
      });
    }
  });
}
