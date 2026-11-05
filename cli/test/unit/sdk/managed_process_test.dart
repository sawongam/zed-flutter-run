import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_run/src/common/errors.dart';
import 'package:flutter_run/src/common/host_environment.dart';
import 'package:flutter_run/src/sdk/managed_process.dart';
import 'package:flutter_run/src/sdk/process_spec.dart';
import 'package:flutter_run/src/sdk/process_tree.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _childScript = '''
import 'dart:async';
import 'dart:io';

void main(List<String> args) {
  if (args.isNotEmpty) File(args.first).writeAsStringSync('\$pid');
  Timer.periodic(const Duration(seconds: 1), (_) {});
}
''';

const _parentScript = '''
import 'dart:io';

Future<void> main(List<String> args) async {
  final child = await Process.start(
    Platform.resolvedExecutable,
    [args[0]],
  );
  print('child \${child.pid}');
  await child.exitCode;
}
''';

const _echoScript = '''
import 'dart:io';

Future<void> main(List<String> args) async {
  stdout.write('out:\${args.join(',')}');
  stderr.write('err');
  await stdout.flush();
  exit(3);
}
''';

Future<bool> isAlive(int pid) async {
  if (Platform.isWindows) {
    final r = await Process.run('tasklist', ['/FI', 'PID eq $pid', '/NH']);
    return (r.stdout as String).contains(RegExp('\\b$pid\\b'));
  }
  final table = await readProcessTable(HostEnvironment.system());
  final info = table.byPid[pid];
  return info != null && !info.zombie;
}

Future<void> eventuallyDead(int pid) async {
  for (var i = 0; i < 100; i++) {
    if (!await isAlive(pid)) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('pid $pid is still alive');
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('rd_proc_'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // A killed process may still hold a handle on Windows.
    }
  });

  String script(String name, String body) {
    final f = File(p.join(tmp.path, name))..writeAsStringSync(body);
    return f.path;
  }

  group('ManagedProcess', () {
    test('terminateTree kills the process and its child', () async {
      final child = script('child.dart', _childScript);
      final parent = script('parent.dart', _parentScript);
      final proc = await ManagedProcess.start(
        ProcessSpec(Platform.resolvedExecutable, [parent, child]),
      );
      addTearDown(() async {
        await proc.terminateTree(grace: const Duration(milliseconds: 200));
      });
      final lines = proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      final line = await lines
          .firstWhere((l) => l.startsWith('child '))
          .timeout(const Duration(seconds: 30));
      final childPid = int.parse(line.substring(6));
      expect(await isAlive(childPid), isTrue);

      final snapshot = await proc.snapshotDescendants();
      expect(snapshot, contains(childPid));
      expect(snapshot, isNot(contains(proc.pid)));

      await proc.terminateTree(grace: const Duration(seconds: 2));
      await proc.exitCode.timeout(const Duration(seconds: 10));
      await eventuallyDead(childPid);
      expect(await isAlive(proc.pid), isFalse);
    });

    test(
      'terminateTree after the parent exited still kills the orphan (snapshot)',
      () async {
        if (Platform.isWindows) {
          markTestSkipped('taskkill /T needs the live parent; covered above');
          return;
        }
        final child = script('child.dart', _childScript);
        final parent = script('parent.dart', _parentScript);
        final proc = await ManagedProcess.start(
          ProcessSpec(Platform.resolvedExecutable, [parent, child]),
        );
        final lines = proc.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter());
        final line = await lines
            .firstWhere((l) => l.startsWith('child '))
            .timeout(const Duration(seconds: 30));
        final childPid = int.parse(line.substring(6));
        final snapshot = await proc.snapshotDescendants();
        expect(snapshot, contains(childPid));
        Process.killPid(proc.pid, ProcessSignal.sigkill);
        await proc.exitCode;
        expect(await isAlive(childPid), isTrue);
        await proc.terminateTree(
          extraPids: snapshot,
          grace: const Duration(seconds: 2),
        );
        await eventuallyDead(childPid);
      },
    );

    test('crash sweep spares shared daemons such as adb', () async {
      final adb = File(p.join(tmp.path, 'adb'))
        ..writeAsStringSync('#!/bin/sh\nwhile :; do sleep 1; done\n');
      Process.runSync('chmod', ['+x', adb.path]);
      final proc = await ManagedProcess.start(
        ProcessSpec('sh', [
          '-c',
          "'${adb.path}' & sleep 62 & echo ready; wait",
        ]),
      );
      await proc.stdout
          .transform(utf8.decoder)
          .firstWhere((s) => s.contains('ready'))
          .timeout(const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final snapshot = await proc.snapshotDescendants();
      final commands = await readCommandLines(
        snapshot,
        HostEnvironment.system(),
      );
      final adbPid = commands.entries
          .firstWhere((e) => e.value.contains(adb.path))
          .key;
      final sleepPid = commands.entries
          .firstWhere((e) => e.value.endsWith('sleep 62'))
          .key;
      addTearDown(() {
        for (final pid in snapshot) {
          Process.killPid(pid, ProcessSignal.sigkill);
        }
      });
      Process.killPid(proc.pid, ProcessSignal.sigkill);
      await proc.exitCode;
      await proc.terminateTree(
        extraPids: snapshot,
        crashed: true,
        grace: const Duration(seconds: 1),
      );
      await eventuallyDead(sleepPid);
      expect(await isAlive(adbPid), isTrue);
    }, skip: Platform.isWindows ? 'POSIX process table' : null);

    test('SIGKILL escalation for a process that ignores TERM', () async {
      final proc = await ManagedProcess.start(
        ProcessSpec('sh', [
          '-c',
          'trap "" TERM; echo ready; while :; do sleep 0.2; done',
        ]),
      );
      await proc.stdout
          .transform(utf8.decoder)
          .firstWhere((s) => s.contains('ready'))
          .timeout(const Duration(seconds: 10));
      final sw = Stopwatch()..start();
      await proc.terminateTree(grace: const Duration(milliseconds: 500));
      final code = await proc.exitCode.timeout(const Duration(seconds: 10));
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(450));
      expect(code, -9, reason: 'killed by SIGKILL');
      expect(await isAlive(proc.pid), isFalse);
    }, skip: Platform.isWindows ? 'POSIX signals' : null);

    test('stdin, stdout and exit code are exposed', () async {
      final proc = await ManagedProcess.start(
        ProcessSpec(Platform.resolvedExecutable, [
          script('echo.dart', _echoScript),
          'a',
          'b',
        ]),
      );
      final out = proc.stdout.transform(utf8.decoder).join();
      final err = proc.stderr.transform(utf8.decoder).join();
      await proc.stdin.close();
      expect(await proc.exitCode, 3);
      expect(await out, 'out:a,b');
      expect(await err, 'err');
      await proc.terminateTree(); // already exited: must be a harmless no-op
    });

    test('a missing executable is an ExternalToolException', () async {
      await expectLater(
        ManagedProcess.start(
          ProcessSpec(p.join(tmp.path, 'does_not_exist'), const []),
        ),
        throwsA(isA<ExternalToolException>()),
      );
    });

    test('environment is added to the inherited one', () async {
      final r = await runTool(
        ProcessSpec(Platform.resolvedExecutable, [
          script(
            'env.dart',
            "import 'dart:io'; void main() { stdout.write(Platform.environment['RD_TEST_VAR']); }",
          ),
        ]),
        environment: {'RD_TEST_VAR': 'hello'},
      );
      expect(r.stdout, 'hello');
    });
  });

  group('runTool', () {
    test('collects output and exit code', () async {
      final r = await runTool(
        ProcessSpec(Platform.resolvedExecutable, [
          script('echo.dart', _echoScript),
          'x',
        ]),
      );
      expect(r.exitCode, 3);
      expect(r.stdout, 'out:x');
      expect(r.stderr, 'err');
    });

    test('timeout kills the child and throws', () async {
      final pidFile = p.join(tmp.path, 'child.pid');
      final child = script('child.dart', _childScript);
      final sw = Stopwatch()..start();
      await expectLater(
        runTool(
          ProcessSpec(Platform.resolvedExecutable, [child, pidFile]),
          timeout: const Duration(seconds: 3),
        ),
        throwsA(
          isA<ExternalToolException>().having(
            (e) => e.message,
            'message',
            contains('did not finish'),
          ),
        ),
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 15)));
      final pid = int.parse(File(pidFile).readAsStringSync());
      await eventuallyDead(pid);
    });
  });
}
