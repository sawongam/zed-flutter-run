import 'dart:io';

import 'package:flutter_run/src/common/host_environment.dart';
import 'package:flutter_run/src/sdk/process_tree.dart';
import 'package:test/test.dart';

const _psGolden = '''
    1     0 Ss   Mon Nov  3 10:00:00 2026
  100     1 S    Mon Nov  3 10:00:01 2026
  101   100 S    Mon Nov  3 10:00:02 2026
  102   100 Sl   Mon Nov  3 10:00:02 2026
  103   102 Z    Mon Nov  3 10:00:03 2026
  200     1 S    Mon Nov  3 10:00:04 2026
garbage line
  abc  def
''';

HostEnvironment posix() => HostEnvironment(
  os: HostOs.linux,
  environment: const {},
  currentDirectory: '/',
);

void main() {
  sharedDaemonTests();
  group('parsePsOutput', () {
    test('golden', () {
      final map = parsePsOutput(_psGolden);
      expect(map, {
        0: [1],
        1: [100, 200],
        100: [101, 102],
        102: [103],
      });
    });
    test('plain "pid ppid" lines, CRLF and blanks', () {
      expect(parsePsOutput('1 0\r\n\r\n 5 1 \r\n'), {
        0: [1],
        1: [5],
      });
    });
    test('empty', () => expect(parsePsOutput(''), isEmpty));
  });

  group('collectDescendants', () {
    final map = parsePsOutput(_psGolden);
    test('golden', () {
      expect(collectDescendants(map, 100), {101, 102, 103});
      expect(collectDescendants(map, 1), {100, 101, 102, 103, 200});
      expect(collectDescendants(map, 101), isEmpty);
      expect(collectDescendants(map, 999), isEmpty);
    });
    test('terminates on cycles and never includes the root', () {
      expect(
        collectDescendants({
          1: [2],
          2: [1],
        }, 1),
        {2},
      );
    });
  });

  group('parseProcessTable', () {
    test('golden', () {
      final t = parseProcessTable(_psGolden);
      expect(t.byPid[101]!.ppid, 100);
      expect(
        t.byPid[101]!.startTime,
        'Mon Nov  3 10:00:02 2026'.replaceAll('  ', ' '),
      );
      expect(t.byPid[103]!.zombie, isTrue);
      expect(t.byPid[102]!.zombie, isFalse);
      expect(t.byPid.containsKey(0), isFalse);
      expect(t.childrenOf[100], [101, 102]);
    });
  });

  group('readProcessTable', () {
    test('sees this process and its parent', () async {
      final t = await readProcessTable(HostEnvironment.system());
      expect(t.byPid[pid]!.ppid, greaterThan(0));
      expect(t.byPid[pid]!.startTime, isNotNull);
      expect(t.byPid.containsKey(t.byPid[pid]!.ppid), isTrue);
    }, skip: Platform.isWindows ? 'POSIX only' : null);

    test('windows reads the table through PowerShell/wmic', () async {
      final env = HostEnvironment(
        os: HostOs.windows,
        environment: const {},
        currentDirectory: r'C:\',
      );
      final table = await readProcessTable(env);
      if (Platform.isWindows) {
        expect(table.byPid, contains(pid));
      } else {
        expect(table.byPid, isEmpty); // neither tool exists here
      }
    });
  });

  group('killTree with a fake process table (PID-reuse guard)', () {
    late List<ProcessTable> tables;
    late List<(int, ProcessSignal)> sent;

    Future<ProcessTable> reader() async =>
        tables.length > 1 ? tables.removeAt(0) : tables.first;
    bool sender(int pid, ProcessSignal s) {
      sent.add((pid, s));
      return true;
    }

    ProcessInfo row(int pid, int ppid, [String? start, bool z = false]) =>
        ProcessInfo(pid, ppid, startTime: start, zombie: z);

    Future<void> run(
      Set<int> snapshot, {
      Map<int, String> starts = const {},
      Duration grace = const Duration(milliseconds: 120),
    }) => killTree(
      10,
      snapshot,
      posix(),
      grace: grace,
      startTimes: starts,
      readTable: reader,
      sendSignal: sender,
    );

    setUp(() {
      sent = [];
    });

    Set<int> pidsOf(ProcessSignal s) => {
      for (final e in sent)
        if (e.$2 == s) e.$1,
    };

    test(
      'live descendants get SIGTERM and nothing else once they exit',
      () async {
        tables = [
          ProcessTable([row(10, 1, 'a'), row(11, 10, 'b'), row(12, 11, 'c')]),
          ProcessTable([row(1, 0)]),
        ];
        await run({11, 12}, starts: {10: 'a', 11: 'b', 12: 'c'});
        expect(pidsOf(ProcessSignal.sigterm), {10, 11, 12});
        expect(pidsOf(ProcessSignal.sigkill), isEmpty);
      },
    );

    test(
      'reparented snapshot pid with the same start time is killed',
      () async {
        tables = [
          ProcessTable([row(1, 0), row(11, 1, 'b')]),
          ProcessTable([row(1, 0)]),
        ];
        await run({11}, starts: {11: 'b'});
        expect(pidsOf(ProcessSignal.sigterm), {11});
      },
    );

    test('reused pid (different start time) is never signalled', () async {
      tables = [
        ProcessTable([row(1, 0), row(11, 1, 'OTHER'), row(12, 1, 'OTHER2')]),
      ];
      await run({11, 12}, starts: {11: 'b', 12: 'c'});
      expect(sent, isEmpty);
    });

    test(
      'reused pid under the root with a different start time is skipped',
      () async {
        tables = [
          ProcessTable([row(10, 1, 'a'), row(11, 10, 'NEW')]),
          ProcessTable([row(1, 0)]),
        ];
        await run({11}, starts: {10: 'a', 11: 'old'});
        expect(pidsOf(ProcessSignal.sigterm), {10});
      },
    );

    test('unknown start time and no longer a descendant: left alone', () async {
      tables = [
        ProcessTable([row(1, 0), row(11, 1, 'b')]),
      ];
      await run({11});
      expect(sent, isEmpty);
    });

    test('pids 0 and 1 are never signalled', () async {
      tables = [
        ProcessTable([row(1, 0, 's'), row(10, 1, 'a')]),
        ProcessTable([row(1, 0, 's')]),
      ];
      await run({0, 1}, starts: {1: 's', 10: 'a'});
      expect(sent.map((e) => e.$1), [10]);
    });

    test('zombies are not signalled and do not delay', () async {
      tables = [
        ProcessTable([row(10, 1, 'a'), row(11, 10, 'b', true)]),
        ProcessTable([row(11, 1, 'b', true)]),
      ];
      final sw = Stopwatch()..start();
      await run(
        {11},
        starts: {10: 'a', 11: 'b'},
        grace: const Duration(seconds: 5),
      );
      expect(pidsOf(ProcessSignal.sigterm), {10});
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('survivors get SIGKILL after the grace period', () async {
      final stubborn = ProcessTable([row(10, 1, 'a'), row(11, 10, 'b')]);
      var calls = 0;
      Future<ProcessTable> slowReader() async {
        calls++;
        return DateTime.now().isBefore(killAfter)
            ? stubborn
            : ProcessTable([row(1, 0)]);
      }

      killAfter = DateTime.now().add(const Duration(milliseconds: 400));
      await killTree(
        10,
        {11},
        posix(),
        grace: const Duration(milliseconds: 150),
        startTimes: {10: 'a', 11: 'b'},
        readTable: slowReader,
        sendSignal: sender,
      );
      expect(calls, greaterThan(2));
      expect(pidsOf(ProcessSignal.sigterm), {10, 11});
      expect(pidsOf(ProcessSignal.sigkill), {10, 11});
    });
  });

  group('killTree on Windows', () {
    test(
      'runs taskkill /T /F on the root and extra pids without a shell',
      () async {
        final env = HostEnvironment(
          os: HostOs.windows,
          environment: const {},
          currentDirectory: r'C:\',
        );
        final calls = <List<String>>[];
        await killTree(
          1234,
          {5678},
          env,
          readTable: () async => const ProcessTable.empty(),
          runProcess: (exe, args) async {
            expect(exe, 'taskkill');
            calls.add(args);
            return ProcessResult(0, 0, '', '');
          },
        );
        expect(calls, [
          ['/PID', '1234', '/T', '/F'],
          ['/PID', '5678', '/T', '/F'],
        ]);
      },
    );

    final env = HostEnvironment(
      os: HostOs.windows,
      environment: const {},
      currentDirectory: r'C:\',
    );

    test('with a process table: only snapshot pids that are the same '
        'instance are killed, without /T when the root is gone', () async {
      var table = parseWindowsProcessCsv(
        'ProcessId,ParentProcessId,Created,CommandLine\n'
        '600,500,100,"dart.exe run"\n'
        '700,4,999,"notepad.exe"\n',
      );
      final calls = <List<String>>[];
      await killTree(
        -1,
        {600, 700},
        env,
        startTimes: const {600: '100', 700: '50'},
        readTable: () async => table,
        runProcess: (exe, args) async {
          calls.add(args);
          if (args[1] == '600') {
            table = parseWindowsProcessCsv(
              'ProcessId,ParentProcessId,Created\n700,4,999\n',
            );
          }
          return ProcessResult(0, 0, '', '');
        },
      );
      expect(calls, [
        ['/PID', '600', '/F'],
      ]);
    });

    test('a live root is killed with /T', () async {
      var alive = true;
      final table = parseWindowsProcessCsv(
        'ProcessId,ParentProcessId,Created\n10,4,100\n11,10,200\n',
      );
      final calls = <List<String>>[];
      await killTree(
        10,
        const {},
        env,
        readTable: () async => alive ? table : const ProcessTable.empty(),
        runProcess: (exe, args) async {
          calls.add(args);
          alive = false;
          return ProcessResult(0, 0, '', '');
        },
      );
      expect(calls.first, ['/PID', '10', '/T', '/F']);
    });
  });

  group('Windows process table parsing', () {
    test('PowerShell ConvertTo-Csv sample', () {
      const csv =
          '"ProcessId","ParentProcessId","Created","CommandLine"\r\n'
          '"4","0","133000000000000000",""\r\n'
          '"6480","6400","133700000000000001","dart.exe --a=""b c"" run, x"\r\n'
          '"7000","6480","133700000000000002","cmd /c ""echo hi"""\r\n';
      final table = parseWindowsProcessCsv(csv);
      expect(table.byPid.keys, containsAll([4, 6480, 7000]));
      expect(table.byPid[6480]!.ppid, 6400);
      expect(table.byPid[6480]!.command, 'dart.exe --a="b c" run, x');
      expect(table.byPid[4]!.command, isNull);
      expect(table.byPid[7000]!.created, 133700000000000002);
      expect(collectDescendants(table.childrenOf, 6400), {6480, 7000});
    });

    test('wmic /format:csv sample (columns by name)', () {
      const csv =
          '\r\nNode,CommandLine,CreationDate,ParentProcessId,ProcessId\r\n'
          'BOX,"a.exe -v",20261103230557.123456+000,100,200\r\n'
          'BOX,,20261103230558.000000+000,200,300\r\n';
      final table = parseWindowsProcessCsv(csv);
      expect(table.byPid[200]!.ppid, 100);
      expect(table.byPid[200]!.command, 'a.exe -v');
      expect(table.byPid[200]!.created, 20261103230557);
      expect(collectDescendants(table.childrenOf, 100), {200, 300});
    });

    test('a child created before its parent is a reused pid, not a child', () {
      final table = parseWindowsProcessCsv(
        'ProcessId,ParentProcessId,Created\n50,4,500\n6532,50,100\n',
      );
      expect(collectDescendants(table.childrenOf, 50), isEmpty);
    });

    test('garbage and missing columns give an empty table', () {
      expect(parseWindowsProcessCsv('').byPid, isEmpty);
      expect(parseWindowsProcessCsv('a,b\n1,2\n').byPid, isEmpty);
      expect(
        parseWindowsProcessCsv('ProcessId,ParentProcessId\nx,y\n').byPid,
        isEmpty,
      );
    });

    test('the daemon filter knows Windows command lines', () {
      for (final c in [
        r'"C:\Android\platform-tools\adb.exe" -L tcp:5037 fork-server server',
        r'C:\jdk\bin\java.exe -cp x org.gradle.launcher.daemon.bootstrap.GradleDaemon 8',
        r'dart.exe tooling-daemon --machine',
      ]) {
        expect(isSharedDaemonCommand(c), isTrue, reason: c);
      }
      expect(isSharedDaemonCommand(r'C:\dart\dart.exe debug_adapter'), isFalse);
    });

    test('the fixed PowerShell and wmic commands take no user input', () {
      expect(windowsPowerShellArgs.first, '-NoProfile');
      expect(windowsPowerShellArgs.last, contains('ConvertTo-Csv'));
      expect(windowsWmicArgs, contains('/format:csv'));
    });
  });
}

void sharedDaemonTests() {
  group('shared daemons (ADR 0007 P1)', () {
    test('adb, Gradle, Kotlin and the Dart tooling daemon are recognised', () {
      for (final c in [
        '/home/u/Android/Sdk/platform-tools/adb -L tcp:5037 fork-server server',
        'adb',
        '/usr/lib/jvm/bin/java -Xmx64m org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.5',
        'java ... org.gradle.wrapper.GradleWrapperMain assembleDebug',
        'java -cp kotlin-compiler-embeddable.jar org.jetbrains.kotlin.daemon.KotlinCompileDaemon',
        '/sdk/dart-sdk/bin/dart tooling-daemon --machine',
        'dart ... DartToolingDaemon',
      ]) {
        expect(isSharedDaemonCommand(c), isTrue, reason: c);
      }
    });

    test('the adapter, DDS and app processes are not', () {
      for (final c in [
        '/sdk/bin/cache/dart-sdk/bin/dart debug_adapter',
        'dart development-service --vm-service-uri=http://127.0.0.1:1/',
        '/sdk/bin/cache/artifacts/engine/linux-x64/flutter_tester app.dill',
        'sleep 600',
        '/usr/bin/gadbuilder',
      ]) {
        expect(isSharedDaemonCommand(c), isFalse, reason: c);
      }
    });

    test('parseCommandLines reads pid and command', () {
      expect(parseCommandLines('  12 /bin/sleep 5\n 13 adb server\nbad\n'), {
        12: '/bin/sleep 5',
        13: 'adb server',
      });
    });
  });
}

late DateTime killAfter;
