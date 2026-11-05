// Fake Zed: drives the proxy end-to-end. Exit 0 on success.
// Usage: dart run bin/fake_client.dart [--with-type] [--out <dir>]
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:spike/framing.dart';

const bpLine = 7;
late final String appDir;
late final File mainFile;
String? original;
final sw = Stopwatch()..start();
final timings = <String, int>{};

void step(String s) => stdout.writeln('[${sw.elapsedMilliseconds.toString().padLeft(6)}ms] $s');

class Fail implements Exception {
  final String msg;
  Fail(this.msg);
  @override
  String toString() => msg;
}

class Client {
  final Process proc;
  final events = <Map<String, dynamic>>[];
  final outputs = <String>[];
  final _waiters = <_Waiter>[];
  final _responses = <int, Completer<Map<String, dynamic>>>{};
  int _seq = 1;
  final _dec = DapDecoder();

  Client(this.proc) {
    proc.stdout.listen((c) {
      for (final m in _dec.add(c)) {
        _handle(m);
      }
    });
    proc.stderr.listen((c) => stderr.add(c));
  }

  void _handle(Map<String, dynamic> m) {
    final t = m['type'];
    if (t == 'response') {
      _responses.remove(m['request_seq'])?.complete(m);
    } else if (t == 'event') {
      events.add(m);
      if (m['event'] == 'output') {
        final o = (m['body'] as Map)['output'] as String;
        outputs.add(o);
        stdout.write('    out> ${o.endsWith('\n') ? o : '$o\n'}');
      }
      for (final w in List.of(_waiters)) {
        if (w.test(m)) {
          _waiters.remove(w);
          w.c.complete(m);
        }
      }
    } else if (t == 'request') {
      // reverse request from adapter: refuse politely
      _send({
        'seq': _seq++,
        'type': 'response',
        'request_seq': m['seq'],
        'success': false,
        'command': m['command'],
        'message': 'fake client does not support ${m['command']}',
      });
    }
  }

  void _send(Map<String, dynamic> m) => proc.stdin.add(encodeDap(m));

  /// Sends a request; returns the future of its response.
  Future<Map<String, dynamic>> request(String cmd, [Map<String, dynamic>? args]) {
    final seq = _seq++;
    final c = Completer<Map<String, dynamic>>();
    _responses[seq] = c;
    _send({'seq': seq, 'type': 'request', 'command': cmd, if (args != null) 'arguments': args});
    return c.future;
  }

  Future<Map<String, dynamic>> call(String cmd, [Map<String, dynamic>? args, int secs = 60]) async {
    final r = await request(cmd, args).timeout(Duration(seconds: secs),
        onTimeout: () => throw Fail('timeout waiting for response to $cmd'));
    if (r['success'] != true) throw Fail('$cmd failed: ${jsonEncode(r)}');
    return r;
  }

  /// Waits for an event matching [test] that arrives after [fromIndex] in events.
  Future<Map<String, dynamic>> waitEvent(String what, bool Function(Map<String, dynamic>) test,
      {int fromIndex = 0, int secs = 90}) {
    for (var i = fromIndex; i < events.length; i++) {
      if (test(events[i])) return Future.value(events[i]);
    }
    final w = _Waiter(test);
    _waiters.add(w);
    return w.c.future.timeout(Duration(seconds: secs), onTimeout: () {
      _waiters.remove(w);
      throw Fail('timeout waiting for $what');
    });
  }

  Future<Map<String, dynamic>> waitStopped(int from, String what) =>
      waitEvent('breakpoint stop ($what)',
          (e) => e['event'] == 'stopped' && (e['body'] as Map)['reason'] == 'breakpoint',
          fromIndex: from);

  Future<Map<String, dynamic>> waitOutput(String needle, int fromOutput, {int secs = 60}) async {
    final end = DateTime.now().add(Duration(seconds: secs));
    while (DateTime.now().isBefore(end)) {
      for (var i = fromOutput; i < outputs.length; i++) {
        if (outputs[i].contains(needle)) return {'index': i};
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }
    throw Fail('timeout waiting for output "$needle"');
  }
}

class _Waiter {
  final bool Function(Map<String, dynamic>) test;
  final c = Completer<Map<String, dynamic>>();
  _Waiter(this.test);
}

Future<void> assertTopFrame(Client c, Map<String, dynamic> stopped, String what) async {
  final body = stopped['body'] as Map;
  if (body['reason'] != 'breakpoint') throw Fail('$what: stopped reason ${body['reason']}');
  final tid = body['threadId'];
  final st = await c.call('stackTrace', {'threadId': tid, 'startFrame': 0, 'levels': 5});
  final frames = (st['body'] as Map)['stackFrames'] as List;
  final top = frames.first as Map;
  final path = (top['source'] as Map?)?['path'];
  step('$what: top frame ${top['name']} ${path}:${top['line']}');
  if (top['line'] != bpLine || !(path as String).endsWith('lib/main.dart')) {
    throw Fail('$what: expected lib/main.dart:$bpLine, got $path:${top['line']}');
  }
}

Future<ProcessResult> control(String sessionFile, String cmd) =>
    Process.run('dart', ['${Directory.current.path}/bin/reload.dart', '--session-file', sessionFile, cmd]);

Future<Set<int>> descendants(int root) async {
  final r = await Process.run('ps', ['-eo', 'pid=,ppid=']);
  final kids = <int, List<int>>{};
  for (final l in (r.stdout as String).split('\n')) {
    final p = l.trim().split(RegExp(r'\s+'));
    if (p.length == 2) kids.putIfAbsent(int.parse(p[1]), () => []).add(int.parse(p[0]));
  }
  final out = <int>{};
  void walk(int p) {
    for (final k in kids[p] ?? const <int>[]) {
      if (out.add(k)) walk(k);
    }
  }
  walk(root);
  return out;
}

Future<void> main(List<String> args) async {
  final withType = args.contains('--with-type');
  final oi = args.indexOf('--out');
  final outDir = Directory(oi >= 0 ? args[oi + 1] : '${Directory.systemTemp.path}/spike_out')
    ..createSync(recursive: true);
  final spikeDir = Directory.current.path;
  appDir = File('$spikeDir/../fixtures/sample_app').absolute.resolveSymbolicLinksSync();
  mainFile = File('$appDir/lib/main.dart');
  original = mainFile.readAsStringSync();
  final logPath = '${outDir.path}/proxy.log';
  final sessionFile = '${outDir.path}/session.json';
  if (File(sessionFile).existsSync()) File(sessionFile).deleteSync();

  Process? proc;
  var ok = false;
  try {
    if (!original!.contains("kGreeting = 'Hello v1'")) throw Fail('main.dart not at v1 state');
    proc = await Process.start('dart', [
      '$spikeDir/bin/proxy.dart', '--log', logPath, '--session-file', sessionFile,
      if (args.contains('--no-mitigation')) '--no-terminate-on-disconnect',
    ]);
    final c = Client(proc);

    step('initialize');
    await c.call('initialize', {
      'clientID': 'zed', 'clientName': 'Zed', 'adapterID': 'Flutter', 'locale': 'en-US',
      'pathFormat': 'path', 'linesStartAt1': true, 'columnsStartAt1': true,
      'supportsVariableType': true, 'supportsVariablePaging': false,
      'supportsRunInTerminalRequest': true, 'supportsStartDebuggingRequest': true,
      'supportsMemoryReferences': true, 'supportsProgressReporting': false,
      'supportsInvalidatedEvent': false, 'supportsMemoryEvent': false,
      'supportsArgsCanBeInterpretedByShell': false, 'supportsANSIStyling': true,
    });

    step('launch (not awaited, like Zed)');
    final launchSw = Stopwatch()..start();
    final launchResp = c.request('launch', {
      if (withType) ...{'type': 'flutter', 'request': 'launch'},
      'program': 'lib/main.dart',
      'cwd': appDir,
      'toolArgs': ['-d', 'flutter-tester', '--show-test-device'],
    });
    await c.waitEvent('initialized', (e) => e['event'] == 'initialized');
    step('got initialized');

    final bpResp = await c.call('setBreakpoints', {
      'source': {'path': '$appDir/lib/main.dart'},
      'breakpoints': [{'line': bpLine}],
    });
    step('setBreakpoints -> ${jsonEncode((bpResp['body'] as Map)['breakpoints'])}');
    await c.call('configurationDone');
    var evIdx = c.events.length;

    // (a)
    // --start-paused: the adapter emits a transient stopped(reason=entry) and then
    // resumes by itself once the app has started. Continuing it ourselves races
    // with the adapter's own resume and swallows the breakpoint hit, so we ignore
    // non-breakpoint stops.
    final stopped1 = await c.waitStopped(0, 'initial');
    timings['launch_to_stopped_ms'] = launchSw.elapsedMilliseconds;
    await assertTopFrame(c, stopped1, '(a) initial');
    await c.call('continue', {'threadId': (stopped1['body'] as Map)['threadId']});
    final lr = await launchResp.timeout(const Duration(seconds: 60));
    step('launch response success=${lr['success']}');
    await c.waitOutput('GREETING: Hello v1', 0);
    await c.waitEvent('flutter.appStarted', (e) => e['event'] == 'flutter.appStarted');
    step('(a) PASS: breakpoint hit through proxy; app started with Hello v1');
    final kinds = c.events.map((e) => e['event']).toSet().toList();
    step('event kinds seen: $kinds');
    final s = jsonDecode(File(sessionFile).readAsStringSync());
    step('session file keys: ${(s as Map).keys.toList()}');
    final st = jsonDecode((await control(sessionFile, 'status')).stdout as String);
    step('proxy captured vmServiceUri: ${st['vmServiceUri']}');
    if (st['vmServiceUri'] == null) throw Fail('proxy did not capture vmServiceUri');

    // (b)+(c) via hot reload. reassemble() calls bump(), so the breakpoint fires
    // *during* reload and the reload only completes after we continue.
    step('rewriting kGreeting -> Hello v2');
    mainFile.writeAsStringSync(original!.replaceFirst("kGreeting = 'Hello v1'", "kGreeting = 'Hello v2'"));
    var outIdx = c.outputs.length;
    evIdx = c.events.length;
    final reloadSw = Stopwatch()..start();
    final reloadFut = control(sessionFile, 'reload');
    final stopped2 = await c.waitStopped(evIdx, 'during reload');
    await assertTopFrame(c, stopped2, '(c) after reload');
    await c.call('continue', {'threadId': (stopped2['body'] as Map)['threadId']});
    final rr = await reloadFut.timeout(const Duration(seconds: 90));
    timings['reload_total_ms'] = reloadSw.elapsedMilliseconds;
    step('reload control result: ${(rr.stdout as String).trim()} ${rr.stderr}');
    final rj = jsonDecode((rr.stdout as String).trim()) as Map;
    if (rj['ok'] != true) throw Fail('reload failed');
    timings['reload_proxy_reported_ms'] = rj['durationMs'] as int;
    await c.waitOutput('GREETING: Hello v2', outIdx);
    step('(b) PASS: reload produced Hello v2 in app output');
    step('(c) PASS: breakpoint hit again after reload');

    // restart
    outIdx = c.outputs.length;
    evIdx = c.events.length;
    final restartSw = Stopwatch()..start();
    final restartFut = control(sessionFile, 'restart');
    final stopped3 = await c.waitStopped(evIdx, 'during restart');
    await assertTopFrame(c, stopped3, 'restart');
    await c.call('continue', {'threadId': (stopped3['body'] as Map)['threadId']});
    final xr = await restartFut.timeout(const Duration(seconds: 90));
    timings['restart_total_ms'] = restartSw.elapsedMilliseconds;
    step('restart control result: ${(xr.stdout as String).trim()}');
    if ((jsonDecode((xr.stdout as String).trim()) as Map)['ok'] != true) throw Fail('restart failed');
    await c.waitOutput('GREETING: Hello v2', outIdx);
    step('restart PASS: main() re-ran (Hello v2 printed) and breakpoint hit again');

    // Verify no response to injected seq leaked to client
    // (client would have ignored unknown request_seq silently; check log instead)
    final logTxt = File(logPath).readAsStringSync();
    final leaked = RegExp(r'A>C \{"seq":\d+,"type":"response","request_seq":1000000\d+').hasMatch(logTxt);
    if (leaked) throw Fail('injected response leaked to client');
    step('no injected-request responses forwarded to client: OK');

    // cleanup
    final proxyPid = proc.pid;
    final kids = await descendants(proxyPid);
    final procNames = <int, String>{};
    for (final k in kids) {
      final r = await Process.run('ps', ['-o', 'args=', '-p', '$k']);
      procNames[k] = (r.stdout as String).trim();
    }
    step('process tree before disconnect: proxy=$proxyPid descendants=$procNames');
    if (args.contains('--terminate-first')) {
      step('sending terminate first');
      await c.call('terminate', null, 30);
    }
    await c.call('disconnect', {'terminateDebuggee': true}, 30);
    final code = await proc.exitCode.timeout(const Duration(seconds: 30),
        onTimeout: () => throw Fail('proxy did not exit after disconnect'));
    step('proxy exited with $code');
    // Poll (up to 10s) for processes to go away instead of a fixed sleep.
    var alive = <int>[];
    for (var i = 0; i < 50; i++) {
      alive = [for (final p in {proxyPid, ...kids}) if (_isAlive(p)) p];
      if (alive.isEmpty) break;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if (alive.isNotEmpty) throw Fail('orphans still alive: ${[for (final p in alive) '$p ${procNames[p]}']}');
    step('cleanup PASS: proxy + ${kids.length} descendants gone');
    if (File(sessionFile).existsSync()) step('NOTE session file still present');
    ok = true;
  } on Fail catch (e) {
    stderr.writeln('FAIL: $e');
  } catch (e, st) {
    stderr.writeln('FAIL (unexpected): $e\n$st');
  } finally {
    mainFile.writeAsStringSync(original!);
    if (!ok && proc != null) {
      final kids = await descendants(proc.pid);
      proc.kill();
      for (final k in kids) {
        Process.killPid(k);
      }
    }
  }
  step('timings: $timings');
  step(ok ? 'RESULT: PASS' : 'RESULT: FAIL');
  exit(ok ? 0 : 1);
}

bool _isAlive(int p) {
  try {
    final stat = File('/proc/$p/stat').readAsStringSync();
    return !stat.contains(') Z '); // zombie == dead for our purposes
  } catch (_) {
    return false;
  }
}
