// DAP proxy: stdio <-> `flutter debug_adapter`, with a localhost control server.
// Usage: dart run bin/proxy.dart --log <p> --session-file <p> [--flutter <path>]
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:spike/framing.dart';

const injectedSeqBase = 1000000000;

Future<void> main(List<String> args) async {
  String? logPath, sessionPath;
  var terminateOnDisconnect = true;
  var flutter = 'flutter';
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--log':
        logPath = args[++i];
      case '--session-file':
        sessionPath = args[++i];
      case '--flutter':
        flutter = args[++i];
      case '--no-terminate-on-disconnect':
        terminateOnDisconnect = false;
    }
  }
  final logSink = logPath == null ? null : File(logPath).openWrite();
  final sw = Stopwatch()..start();
  void log(String dir, Object? msg) =>
      logSink?.writeln('${sw.elapsedMilliseconds}ms $dir ${msg is String ? msg : jsonEncode(msg)}');

  final adapter = await Process.start(flutter, ['debug_adapter']);
  log('SYS', 'spawned flutter debug_adapter pid=${adapter.pid}');
  adapter.stderr.listen((d) {
    log('ERR', utf8.decode(d, allowMalformed: true));
    stderr.add(d);
  });

  String? vmServiceUri;
  var nextSeq = injectedSeqBase;
  final pending = <int, Completer<Map<String, dynamic>>>{};

  adapter.stdin.done.catchError((_) {});
  void toAdapter(Map<String, dynamic> m) {
    try {
      adapter.stdin.add(encodeDap(m));
    } catch (e) {
      log('SYS', 'write to adapter failed: $e');
    }
  }

  Future<Map<String, dynamic>> inject(String command, Map<String, dynamic> a) {
    final seq = nextSeq++;
    final c = Completer<Map<String, dynamic>>();
    pending[seq] = c;
    final msg = {'seq': seq, 'type': 'request', 'command': command, 'arguments': a};
    log('INJ', msg);
    toAdapter(msg);
    return c.future;
  }

  // client -> adapter
  final cDec = DapDecoder();
  final clientDone = Completer<void>();
  stdin.listen((chunk) {
    for (final m in cDec.add(chunk)) {
      log('C>A', m);
      if (terminateOnDisconnect && m['type'] == 'request' && m['command'] == 'disconnect') {
        // Plain `disconnect` leaves flutter_tester + DDS orphaned (see README);
        // a `terminate` first makes the adapter shut the app down properly.
        inject('terminate', {})
            .timeout(const Duration(seconds: 20))
            .then((_) {}, onError: (_) {})
            .whenComplete(() => toAdapter(m));
      } else {
        toAdapter(m);
      }
    }
  }, onDone: () {
    log('SYS', 'client stdin closed');
    if (!clientDone.isCompleted) clientDone.complete();
  });

  // adapter -> client
  final aDec = DapDecoder();
  final adapterDone = Completer<void>();
  adapter.stdout.listen((chunk) {
    for (final m in aDec.add(chunk)) {
      log('A>C', m);
      if (m['type'] == 'event' && m['event'] == 'dart.debuggerUris') {
        vmServiceUri = (m['body'] as Map?)?['vmServiceUri'] as String?;
        log('SYS', 'captured vmServiceUri=$vmServiceUri');
      }
      if (m['type'] == 'response' && pending.containsKey(m['request_seq'])) {
        pending.remove(m['request_seq'])!.complete(m);
        continue; // swallow responses to injected requests
      }
      stdout.add(encodeDap(m));
    }
  }, onDone: () {
    if (!adapterDone.isCompleted) adapterDone.complete();
  });

  // control server
  final token = List.generate(16, (_) => Random.secure().nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  if (sessionPath != null) {
    File(sessionPath).writeAsStringSync(jsonEncode(
        {'port': server.port, 'token': token, 'pid': pid, 'vmServiceUri': null}));
  }
  server.listen((sock) {
    utf8.decoder.bind(sock).transform(const LineSplitter()).listen((line) async {
      Map<String, dynamic> reply;
      try {
        final req = jsonDecode(line) as Map<String, dynamic>;
        if (req['token'] != token) {
          reply = {'ok': false, 'error': 'bad token'};
        } else {
          final cmd = req['command'];
          final dapCmd = cmd == 'reload'
              ? 'hotReload'
              : cmd == 'restart'
                  ? 'hotRestart'
                  : null;
          if (cmd == 'status') {
            reply = {'ok': true, 'vmServiceUri': vmServiceUri};
          } else if (dapCmd == null) {
            reply = {'ok': false, 'error': 'unknown command $cmd'};
          } else {
            final t = Stopwatch()..start();
            final resp = await inject(dapCmd, {'reason': 'manual'})
                .timeout(const Duration(seconds: 60));
            reply = {
              'ok': resp['success'] == true,
              'durationMs': t.elapsedMilliseconds,
              'response': resp,
            };
          }
        }
      } catch (e) {
        reply = {'ok': false, 'error': '$e'};
      }
      sock.writeln(jsonEncode(reply));
      await sock.flush();
    });
  });

  Future<void> shutdown() async {
    await server.close();
    if (sessionPath != null) {
      try {
        File(sessionPath).deleteSync();
      } catch (_) {}
    }
  }

  // Exit when the adapter exits; if client goes away first, give the adapter a
  // moment then kill it.
  unawaited(clientDone.future.then((_) async {
    await Future.any([adapter.exitCode, Future.delayed(const Duration(seconds: 5))]);
    adapter.kill();
  }));
  final code = await adapter.exitCode;
  await adapterDone.future.timeout(const Duration(seconds: 2), onTimeout: () {});
  log('SYS', 'adapter exited $code');
  await shutdown();
  await logSink?.flush();
  await logSink?.close();
  exit(code);
}
