import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_run/src/common/json_types.dart';
import 'package:flutter_run/src/control/control_client.dart';
import 'package:flutter_run/src/control/control_protocol.dart';
import 'package:flutter_run/src/control/control_server.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Sends [payload] raw and returns the reply line (null when the server
/// closes without one).
Future<Json?> raw(int port, List<int> payload, {bool shutdown = false}) async {
  final socket = await Socket.connect('127.0.0.1', port);
  final lines = utf8.decoder
      .bind(socket)
      .transform(const LineSplitter())
      .cast<String>()
      .toList();
  try {
    socket.add(payload);
    await socket.flush();
  } on Object {
    // The server may already have answered and closed.
  }
  if (shutdown) await socket.close();
  final all = await lines.timeout(const Duration(seconds: 5));
  socket.destroy();
  return all.isEmpty ? null : jsonDecode(all.first) as Json;
}

List<int> request(Object? body) => utf8.encode('${jsonEncode(body)}\n');

void main() {
  late FakeControl control;
  late ControlServer server;

  setUp(() async {
    control = FakeControl();
    server = await ControlServer.start(
      control: control,
      requestLineTimeout: const Duration(milliseconds: 300),
    );
  });

  tearDown(() => server.close());

  Json good(String command, {Object? args}) => {
    'v': 1,
    'token': server.token,
    'id': 7,
    'command': command,
    'args': ?args,
  };

  test('token is 32 random bytes in base64url without padding', () {
    expect(server.token, hasLength(43));
    expect(server.token, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
  });

  test('binds loopback only', () async {
    expect(server.port, greaterThan(0));
    // Connecting via the IPv4 loopback address works.
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    socket.destroy();
  });

  test('good token: ping, reload (args passed), restart', () async {
    final ping = await raw(server.port, request(good('ping')));
    expect(ping, {
      'v': 1,
      'id': 7,
      'ok': true,
      'result': {'pid': 4242, 'version': '0.1.0', 'protocol': 1},
    });
    final reload = await raw(
      server.port,
      request(good('reload', args: {'reason': 'manual'})),
    );
    expect(reload!['ok'], true);
    expect((reload['result'] as Json)['durationMs'], 593);
    expect(control.reloadArgs, [
      {'reason': 'manual'},
    ]);
    final restart = await raw(server.port, request(good('restart')));
    expect(restart!['ok'], true);
  });

  Future<void> expectError(Object? body, String code, {int? id}) async {
    final reply = await raw(server.port, request(body));
    expect(reply!['ok'], false);
    expect((reply['error'] as Json)['code'], code);
  }

  test('bad token is unauthorized, before the command lookup', () async {
    await expectError({...good('ping'), 'token': 'nope'}, 'unauthorized');
    await expectError({...good('bogus'), 'token': 'nope'}, 'unauthorized');
    await expectError({...good('ping')}..remove('token'), 'unauthorized');
    expect(control.reloadArgs, isEmpty);
  });

  test('unknown command with a valid token', () async {
    await expectError(good('shutdown'), 'unknown_command');
  });

  test('no protocol details leak before authentication', () async {
    final reply = await raw(
      server.port,
      request({...good('ping'), 'v': 2, 'token': 'nope', 'id': 'x'}),
    );
    expect((reply!['error'] as Json)['code'], 'unauthorized');
    expect(reply['id'], isNull);
    expect(jsonEncode(reply), isNot(contains('version')));
    final noVersion = await raw(
      server.port,
      request({'token': 'nope', 'command': 5}),
    );
    expect((noVersion!['error'] as Json)['code'], 'unauthorized');
  });

  test(
    'pending connections are capped: extra ones get busy, not silence',
    () async {
      final idle = <Socket>[];
      for (var i = 0; i < ControlServer.maxPendingConnections; i++) {
        idle.add(await Socket.connect('127.0.0.1', server.port));
      }
      addTearDown(() {
        for (final s in idle) {
          s.destroy();
        }
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final reply = await raw(server.port, request(good('ping')));
      expect(reply!['ok'], false);
      expect((reply['error'] as Json)['code'], 'busy');
    },
  );

  test('total connections are capped: the extra one gets busy', () async {
    // Handlers stay busy until the server is closed, so the held connections
    // are not released while a slow runner is still accepting the burst.
    final slow = await ControlServer.start(
      control: FakeControl(reloadDelay: const Duration(seconds: 60)),
      tokenOverrideForTests: 'fixed',
    );
    final held = <Socket>[];
    addTearDown(() async {
      for (final s in held) {
        s.destroy();
      }
      await slow.close();
    });
    final line = request({'v': 1, 'token': 'fixed', 'command': 'reload'});
    for (var i = 0; i < ControlServer.maxConnections; i++) {
      final socket = await Socket.connect('127.0.0.1', slow.port);
      socket.listen((_) {}, onError: (Object _) {});
      socket.add(line);
      held.add(socket);
    }
    // Windows accepts a burst of connections slowly: poll until all are in.
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (slow.connectionCount < ControlServer.maxConnections) {
      expect(DateTime.now().isBefore(deadline), isTrue, reason: 'not accepted');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final extra = await raw(slow.port, line);
    expect((extra!['error'] as Json)['code'], 'busy');
  });

  test('unsupported version', () async {
    await expectError({...good('ping'), 'v': 2}, 'unsupported_version');
  });

  test('strict JSON: garbage and wrong shapes are bad_request', () async {
    for (final line in ['not json', '[1,2]', '"x"', '{"v":1,}', '']) {
      final reply = await raw(server.port, utf8.encode('$line\n'));
      expect(reply!['ok'], false, reason: line);
      expect((reply['error'] as Json)['code'], 'bad_request', reason: line);
    }
    await expectError({...good('ping'), 'v': '1'}, 'bad_request');
    await expectError({...good('ping'), 'command': 5}, 'bad_request');
    await expectError({
      ...good('ping'),
      'args': [1],
    }, 'bad_request');
    await expectError({...good('ping'), 'id': <Object?>[]}, 'bad_request');
  });

  test('invalid UTF-8 is bad_request', () async {
    final reply = await raw(server.port, [0xff, 0xfe, 10]);
    expect((reply!['error'] as Json)['code'], 'bad_request');
  });

  test('oversize line (70 KiB) is payload_too_large', () async {
    final big = utf8.encode('${'a' * (70 * 1024)}\n');
    final reply = await raw(server.port, big);
    expect(reply!['ok'], false);
    expect((reply['error'] as Json)['code'], 'payload_too_large');
  });

  test('oversize line without newline is payload_too_large', () async {
    final reply = await raw(server.port, utf8.encode('a' * (70 * 1024)));
    expect((reply!['error'] as Json)['code'], 'payload_too_large');
  });

  test('a line just under the limit is accepted', () async {
    final body = jsonEncode({...good('ping'), 'pad': 'x' * 60000});
    final reply = await raw(server.port, utf8.encode('$body\n'));
    expect(reply!['ok'], true);
  });

  test('idle connection is closed after the request-line timeout', () async {
    final socket = await Socket.connect('127.0.0.1', server.port);
    final watch = Stopwatch()..start();
    final data = await socket.toList().timeout(const Duration(seconds: 5));
    expect(data, isEmpty);
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(250));
    socket.destroy();
  });

  test('a slow handler is not subject to the idle timeout', () async {
    final slow = await ControlServer.start(
      control: FakeControl(reloadDelay: const Duration(milliseconds: 800)),
      requestLineTimeout: const Duration(milliseconds: 200),
      tokenOverrideForTests: 'fixed',
    );
    addTearDown(slow.close);
    final reply = await raw(
      slow.port,
      request({'v': 1, 'token': 'fixed', 'command': 'reload'}),
    );
    expect(reply!['ok'], true);
    expect(reply['id'], isNull);
  });

  test('handler ControlException maps to its code', () async {
    control.reloadError = const ControlException(
      ControlErrorCode.busy,
      'A restart is running.',
    );
    final reply = await raw(server.port, request(good('reload')));
    expect(reply!['error'], {
      'code': 'busy',
      'message': 'A restart is running.',
    });
  });

  test('unexpected handler error is internal without details', () async {
    control.reloadError = StateError('secret detail');
    final reply = await raw(server.port, request(good('reload')));
    final error = reply!['error'] as Json;
    expect(error['code'], 'internal');
    expect(error['message'], isNot(contains('secret')));
  });

  test('concurrent requests are all answered', () async {
    final slow = await ControlServer.start(
      control: FakeControl(reloadDelay: const Duration(milliseconds: 300)),
      tokenOverrideForTests: 'fixed',
    );
    addTearDown(slow.close);
    final replies = await Future.wait([
      // Below the cap on connections that have not sent their line yet.
      for (var i = 0; i < 12; i++)
        raw(
          slow.port,
          request({'v': 1, 'token': 'fixed', 'id': i, 'command': 'reload'}),
        ),
    ]);
    expect([for (final r in replies) r!['id']], List.generate(12, (i) => i));
    expect(replies.every((r) => r!['ok'] == true), isTrue);
  });

  test(
    'client/server round trip incl. errors and transport failures',
    () async {
      final client = ControlClient();
      final info = sessionInfo(port: server.port, token: server.token);
      final ok = await client.send(info, 'reload', args: {'reason': 'manual'});
      expect(ok.ok, isTrue);
      expect(ok.result!['durationMs'], 593);

      final denied = await client.send(info.copyWith(token: 'bad'), 'ping');
      expect(denied.ok, isFalse);
      expect(denied.errorCode, ControlErrorCode.unauthorized);

      final unknown = await client.send(info, 'bogus');
      expect(unknown.errorCode, ControlErrorCode.unknownCommand);

      expect(
        await client.ping(
          sessionInfo(port: server.port, token: server.token, pid: 4242),
        ),
        PingOutcome.alive,
      );
      // A different pid than the one in the file means another process.
      expect(await client.ping(info.copyWith(pid: 1)), PingOutcome.stale);

      final port = server.port;
      await server.close();
      await expectLater(
        client.send(info.copyWith(port: port), 'ping'),
        throwsA(
          isA<ControlClientException>().having(
            (e) => e.failure,
            'failure',
            ControlClientFailure.refused,
          ),
        ),
      );
    },
  );

  test('client send times out on a silent server', () async {
    final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    silent.listen(sockets.add);
    addTearDown(() async {
      for (final s in sockets) {
        s.destroy();
      }
      await silent.close();
    });
    await expectLater(
      ControlClient().send(
        sessionInfo(port: silent.port),
        'ping',
        timeout: const Duration(milliseconds: 200),
      ),
      throwsA(
        isA<ControlClientException>().having(
          (e) => e.failure,
          'failure',
          ControlClientFailure.timeout,
        ),
      ),
    );
  });

  test('close stops accepting connections', () async {
    final port = server.port;
    await server.close();
    await expectLater(
      Socket.connect('127.0.0.1', port),
      throwsA(isA<SocketException>()),
    );
  });

  group('constantTimeEquals', () {
    test('equal, different, different length, empty', () {
      expect(constantTimeEquals('abc', 'abc'), isTrue);
      expect(constantTimeEquals('abc', 'abd'), isFalse);
      expect(constantTimeEquals('abc', 'abcd'), isFalse);
      expect(constantTimeEquals('abcd', 'abc'), isFalse);
      expect(constantTimeEquals('', ''), isTrue);
      expect(constantTimeEquals('', 'a'), isFalse);
      expect(constantTimeEquals('é', 'é'), isTrue);
    });
  });
}
