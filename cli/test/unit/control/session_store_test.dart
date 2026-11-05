import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_run/src/common/host_environment.dart';
import 'package:flutter_run/src/control/control_client.dart';
import 'package:flutter_run/src/control/control_server.dart';
import 'package:flutter_run/src/control/find_sessions.dart';
import 'package:flutter_run/src/control/session_info.dart';
import 'package:flutter_run/src/control/session_paths.dart';
import 'package:flutter_run/src/control/session_store.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Pings with a short timeout so unresponsive servers resolve quickly.
class QuickClient extends ControlClient {
  QuickClient({super.connector});

  @override
  Future<PingOutcome> ping(
    SessionInfo session, {
    Duration timeout = const Duration(seconds: 2),
  }) => super.ping(session, timeout: const Duration(milliseconds: 250));
}

class DelayedClient extends ControlClient {
  DelayedClient(this.delay, this.outcome);
  final Duration delay;
  final PingOutcome outcome;
  int calls = 0;

  @override
  Future<PingOutcome> ping(
    SessionInfo session, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    calls++;
    await Future<void>.delayed(delay);
    return outcome;
  }
}

class _RewritingClient extends ControlClient {
  _RewritingClient(this.rewrite);
  final Future<Object?> Function() rewrite;

  @override
  Future<PingOutcome> ping(
    SessionInfo session, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    await rewrite();
    return PingOutcome.stale;
  }
}

void main() {
  late Directory temp;
  late HostEnvironment env;

  setUp(() async {
    temp = await tempDir('fl_rd_store');
    env = hostEnv('${temp.path}/state');
  });
  tearDown(() => temp.delete(recursive: true));

  Future<int> closedPort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }

  group('session files', () {
    test('create writes <pid>.json and the directory is 0700', () async {
      final store = SessionStore(env);
      final handle = await store.create(sessionInfo(pid: 321));
      expect(
        handle.path,
        env.pathContext.join(sessionsDirectory(env), '321.json'),
      );
      final json = jsonDecode(File(handle.path).readAsStringSync()) as Map;
      expect(json['pid'], 321);
      expect(json['version'], 1);
      if (!Platform.isWindows) {
        final mode = FileStat.statSync(sessionsDirectory(env)).mode & 0x1ff;
        expect(mode.toRadixString(8), '700');
      }
    });

    test(
      'update is atomic: readers never see partial content, no temp left',
      () async {
        final store = SessionStore(env);
        final handle = await store.create(sessionInfo(pid: 7));
        var done = false;
        var reads = 0;
        final reader = () async {
          final file = File(handle.path);
          while (!done) {
            final String text;
            try {
              text = file.readAsStringSync();
            } on PathAccessException {
              // Windows: a read can collide with the rename (sharing
              // violation); readers retry, they never see partial content.
              await Future<void>.delayed(Duration.zero);
              continue;
            }
            final info = SessionInfo.fromJson(
              jsonDecode(text) as Map<String, Object?>,
            );
            expect(info.pid, 7);
            reads++;
            // Leave the file alone most of the time so Windows renames
            // are not starved by a reader that always has it open.
            await Future<void>.delayed(const Duration(milliseconds: 2));
          }
        }();
        for (var i = 0; i < 60; i++) {
          await handle.update(
            sessionInfo(
              pid: 7,
              appStarted: i.isEven,
            ).copyWith(vmServiceUri: 'ws://127.0.0.1:1/${'x' * (i * 50)}=/ws'),
          );
        }
        done = true;
        await reader;
        expect(reads, greaterThan(0));
        final names = Directory(sessionsDirectory(env))
            .listSync()
            .map((e) => e.path.split(Platform.pathSeparator).last)
            .toList();
        expect(names, ['7.json']);
      },
    );

    test('overlapping updates are serialised, last call wins', () async {
      final handle = await SessionStore(env).create(sessionInfo(pid: 8));
      await Future.wait([
        for (var i = 0; i < 20; i++)
          handle.update(sessionInfo(pid: 8).copyWith(mode: 'm$i')),
      ]);
      final info = SessionInfo.fromJson(
        jsonDecode(File(handle.path).readAsStringSync())
            as Map<String, Object?>,
      );
      expect(info.mode, 'm19');
    });

    test(
      'delete removes the file, is idempotent and blocks later updates',
      () async {
        final handle = await SessionStore(env).create(sessionInfo(pid: 9));
        await handle.delete();
        expect(File(handle.path).existsSync(), isFalse);
        await handle.delete();
        await handle.update(sessionInfo(pid: 9));
        expect(File(handle.path).existsSync(), isFalse);
      },
    );
  });

  group('list', () {
    test('no directory means no sessions', () async {
      expect(await SessionStore(env).list(), isEmpty);
    });

    test(
      'alive session via a real server is listed (pid check passes)',
      () async {
        final server = await ControlServer.start(control: FakeControl(pid: 55));
        addTearDown(server.close);
        final store = SessionStore(env);
        await store.create(
          sessionInfo(pid: 55, port: server.port, token: server.token),
        );
        final records = await store.list();
        expect(records, hasLength(1));
        expect(records.single.unresponsive, isFalse);
        expect(records.single.info.pid, 55);
      },
    );

    test('connection refused: stale file is deleted', () async {
      final store = SessionStore(env);
      final handle = await store.create(sessionInfo(port: await closedPort()));
      expect(await store.list(), isEmpty);
      expect(File(handle.path).existsSync(), isFalse);
    });

    test('prune: false keeps stale files but still skips them', () async {
      final store = SessionStore(env);
      final handle = await store.create(sessionInfo(port: await closedPort()));
      expect(await store.list(prune: false), isEmpty);
      expect(File(handle.path).existsSync(), isTrue);
    });

    test('connect timeout keeps the file and marks it unresponsive', () async {
      final client = ControlClient(
        connector: (host, port, timeout) async =>
            throw const SocketException('Connection timed out'),
      );
      final store = SessionStore(env, probe: client);
      final handle = await store.create(sessionInfo());
      final records = await store.list();
      expect(records.single.unresponsive, isTrue);
      expect(File(handle.path).existsSync(), isTrue);
    });

    test('refused (by errno) is stale', () async {
      final client = ControlClient(
        connector: (host, port, timeout) async => throw const SocketException(
          'refused',
          osError: OSError('Connection refused', 111),
        ),
      );
      final store = SessionStore(env, probe: client);
      final handle = await store.create(sessionInfo());
      expect(await store.list(), isEmpty);
      expect(File(handle.path).existsSync(), isFalse);
    });

    test('a file rewritten by a new process during the ping is kept', () async {
      late SessionStore store;
      final probe = _RewritingClient(
        () => store.create(sessionInfo(pid: 1, token: 'new-token')),
      );
      store = SessionStore(env, probe: probe);
      final handle = await store.create(sessionInfo(pid: 1, token: 'old'));
      expect(await store.list(), isEmpty);
      expect(File(handle.path).existsSync(), isTrue);
      expect(File(handle.path).readAsStringSync(), contains('new-token'));
    });

    test('connected but silent: kept and marked unresponsive', () async {
      final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      silent.listen(sockets.add);
      addTearDown(() async {
        for (final s in sockets) {
          s.destroy();
        }
        await silent.close();
      });
      final store = SessionStore(env, probe: QuickClient());
      final handle = await store.create(sessionInfo(port: silent.port));
      final records = await store.list();
      expect(records, hasLength(1));
      expect(records.single.unresponsive, isTrue);
      expect(File(handle.path).existsSync(), isTrue);
    });

    test(
      'another service on the port (not our protocol) is stale and pruned',
      () async {
        final replies = [
          'HTTP/1.1 400 Bad Request\r\n\r\n',
          '{"hello":1}\n',
          '[]\n',
        ];
        final servers = <ServerSocket>[];
        final store = SessionStore(env, probe: QuickClient());
        for (var i = 0; i < replies.length; i++) {
          final server = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          servers.add(server);
          server.listen((s) {
            s.write(replies[i]);
            s.close();
          });
          await store.create(sessionInfo(pid: i + 1, port: server.port));
        }
        addTearDown(() => Future.wait(servers.map((s) => s.close())));
        expect(await store.list(), isEmpty);
        expect(Directory(sessionsDirectory(env)).listSync(), isEmpty);
      },
    );

    test('an immediate close with no data is kept as unresponsive', () async {
      final closing = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      closing.listen((s) => s.destroy());
      addTearDown(closing.close);
      final store = SessionStore(env, probe: QuickClient());
      await store.create(sessionInfo(pid: 2, port: closing.port));
      final records = await store.list();
      expect(records.single.unresponsive, isTrue);
      expect(Directory(sessionsDirectory(env)).listSync(), hasLength(1));
    });

    test('a different flutter_run on the port (wrong token) is stale', () async {
      final other = await ControlServer.start(control: FakeControl(pid: 5));
      addTearDown(other.close);
      final store = SessionStore(env);
      await store.create(sessionInfo(pid: 5, port: other.port, token: 'old'));
      expect(await store.list(), isEmpty);
    });

    test('N stale files are pinged concurrently', () async {
      final probe = DelayedClient(
        const Duration(milliseconds: 400),
        PingOutcome.stale,
      );
      final store = SessionStore(env, probe: probe);
      for (var pid = 1; pid <= 8; pid++) {
        await store.create(sessionInfo(pid: pid));
      }
      final watch = Stopwatch()..start();
      expect(await store.list(), isEmpty);
      expect(probe.calls, 8);
      // Sequential pinging would take 3.2 s.
      expect(watch.elapsedMilliseconds, lessThan(1500));
      expect(Directory(sessionsDirectory(env)).listSync(), isEmpty);
    });

    test(
      'other versions, garbage and non-json files are skipped, not deleted',
      () async {
        final store = SessionStore(
          env,
          probe: DelayedClient(Duration.zero, PingOutcome.alive),
        );
        await store.create(sessionInfo(pid: 1));
        final dir = sessionsDirectory(env);
        File('$dir/2.json').writeAsStringSync(
          jsonEncode({...sessionInfo(pid: 2).toJson(), 'version': 2}),
        );
        File('$dir/3.json').writeAsStringSync('{ not json');
        File('$dir/4.json').writeAsStringSync('[]');
        File('$dir/5.json.tmp-abc').writeAsStringSync('partial');
        File('$dir/notes.txt').writeAsStringSync('hi');
        final records = await store.list();
        expect([for (final r in records) r.info.pid], [1]);
        expect(Directory(dir).listSync(), hasLength(6));
      },
    );

    test('sorted by start time, oldest first', () async {
      final store = SessionStore(
        env,
        probe: DelayedClient(Duration.zero, PingOutcome.alive),
      );
      await store.create(
        sessionInfo(pid: 1, startedAt: DateTime.utc(2026, 1, 3)),
      );
      await store.create(
        sessionInfo(pid: 2, startedAt: DateTime.utc(2026, 1, 1)),
      );
      await store.create(
        sessionInfo(pid: 3, startedAt: DateTime.utc(2026, 1, 2)),
      );
      final records = await store.list();
      expect([for (final r in records) r.info.pid], [2, 3, 1]);
    });

    test(
      'findSessionsFor matches project roots and keeps unresponsive',
      () async {
        final probe = DelayedClient(Duration.zero, PingOutcome.alive);
        final store = SessionStore(env, probe: probe);
        await store.create(sessionInfo(pid: 1, projectRoot: '/w/app'));
        await store.create(sessionInfo(pid: 2, projectRoot: '/w/other'));
        await store.create(sessionInfo(pid: 3, projectRoot: '/w/app/example'));
        expect(
          [
            for (final r in await findSessionsFor(store, '/w/app/lib', env))
              r.info.pid,
          ],
          [1],
        );
        expect([
          for (final r in await findSessionsFor(store, '/w', env)) r.info.pid,
        ], unorderedEquals([1, 2, 3]));
        expect([
          for (final r in await findSessionsFor(store, '/w/app', env))
            r.info.pid,
        ], unorderedEquals([1, 3]));
      },
    );
  });
}
