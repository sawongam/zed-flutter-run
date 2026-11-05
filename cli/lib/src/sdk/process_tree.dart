import 'dart:async';
import 'dart:io';

import '../common/host_environment.dart';

/// One row of the process table.
class ProcessInfo {
  const ProcessInfo(
    this.pid,
    this.ppid, {
    this.startTime,
    this.zombie = false,
    this.command,
    this.created,
  });

  final int pid;
  final int ppid;

  /// Opaque start-time token; equal tokens mean the same process instance.
  final String? startTime;
  final bool zombie;

  /// Full command line when the platform table provides it (Windows).
  final String? command;

  /// Sortable creation time (Windows). A child created before its recorded
  /// parent is not a real child: the parent pid was reused (Windows keeps the
  /// stale parent pid of orphans).
  final int? created;
}

class ProcessTable {
  ProcessTable(Iterable<ProcessInfo> rows)
    : byPid = {for (final r in rows) r.pid: r};

  const ProcessTable.empty() : byPid = const <int, ProcessInfo>{};

  final Map<int, ProcessInfo> byPid;

  Map<int, List<int>> get childrenOf {
    final map = <int, List<int>>{};
    for (final r in byPid.values) {
      final parentCreated = byPid[r.ppid]?.created;
      final created = r.created;
      if (parentCreated != null && created != null && created < parentCreated) {
        continue; // the parent pid was reused by an unrelated process
      }
      (map[r.ppid] ??= <int>[]).add(r.pid);
    }
    return map;
  }
}

/// Parses `pid ppid ...` lines (extra columns ignored) into a parent -> children
/// map. Malformed lines are skipped.
Map<int, List<int>> parsePsOutput(String psOutput) {
  final map = <int, List<int>>{};
  for (final line in psOutput.split('\n')) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final pid = int.tryParse(parts[0]);
    final ppid = int.tryParse(parts[1]);
    if (pid == null || ppid == null) continue;
    (map[ppid] ??= <int>[]).add(pid);
  }
  return map;
}

/// Parses `pid ppid stat start...` lines (the format [readProcessTable] asks
/// `ps` for; `start` is the rest of the line). `stat` and `start` are optional.
ProcessTable parseProcessTable(String psOutput) {
  final rows = <ProcessInfo>[];
  for (final raw in psOutput.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final pid = int.tryParse(parts[0]);
    final ppid = int.tryParse(parts[1]);
    if (pid == null || ppid == null) continue;
    final stat = parts.length > 2 ? parts[2] : '';
    final start = parts.length > 3 ? parts.sublist(3).join(' ') : null;
    rows.add(
      ProcessInfo(
        pid,
        ppid,
        startTime: start,
        zombie: stat.toUpperCase().startsWith('Z'),
      ),
    );
  }
  return ProcessTable(rows);
}

/// All transitive descendants of [root] (not including it). Cycle safe.
Set<int> collectDescendants(Map<int, List<int>> childrenOf, int root) {
  final result = <int>{};
  final queue = <int>[root];
  while (queue.isNotEmpty) {
    final current = queue.removeLast();
    for (final child in childrenOf[current] ?? const <int>[]) {
      if (child != root && result.add(child)) queue.add(child);
    }
  }
  return result;
}

/// Splits RFC 4180 CSV text into rows of fields (quotes may contain commas,
/// doubled quotes and line breaks).
List<List<String>> parseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  var any = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(c);
      }
    } else if (c == '"') {
      inQuotes = true;
      any = true;
    } else if (c == ',') {
      row.add(field.toString());
      field.clear();
      any = true;
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      if (any || field.isNotEmpty) {
        row.add(field.toString());
        rows.add(row);
      }
      row = <String>[];
      field.clear();
      any = false;
    } else {
      field.write(c);
      any = true;
    }
  }
  if (any || field.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}

/// Parses the CSV of the Windows process table (PowerShell `ConvertTo-Csv`
/// or `wmic ... /format:csv`). Columns are found by header name, so their
/// order does not matter. `CreationDate`/`Created` is any sortable digits.
ProcessTable parseWindowsProcessCsv(String csv) {
  final rows = parseCsv(csv);
  if (rows.isEmpty) return const ProcessTable.empty();
  final header = [for (final h in rows.first) h.trim().toLowerCase()];
  int col(List<String> names) {
    for (final n in names) {
      final i = header.indexOf(n);
      if (i >= 0) return i;
    }
    return -1;
  }

  final pidCol = col(['processid']);
  final ppidCol = col(['parentprocessid']);
  final createdCol = col(['created', 'creationdate']);
  final commandCol = col(['commandline']);
  if (pidCol < 0 || ppidCol < 0) return const ProcessTable.empty();
  final out = <ProcessInfo>[];
  for (final r in rows.skip(1)) {
    if (r.length <= pidCol || r.length <= ppidCol) continue;
    final pid = int.tryParse(r[pidCol].trim());
    final ppid = int.tryParse(r[ppidCol].trim());
    if (pid == null || ppid == null) continue;
    String? token;
    int? created;
    if (createdCol >= 0 && createdCol < r.length) {
      token = r[createdCol].trim();
      final digits = token.replaceAll(RegExp(r'[^0-9]'), '');
      // wmic dates end with a +/-offset; drop it so the digits sort.
      final main = token
          .split(RegExp(r'[.+\-]'))
          .first
          .replaceAll(RegExp(r'[^0-9]'), '');
      created = int.tryParse(main.isEmpty ? digits : main);
      if (token.isEmpty) token = null;
    }
    final command = commandCol >= 0 && commandCol < r.length
        ? r[commandCol]
        : null;
    out.add(
      ProcessInfo(
        pid,
        ppid,
        startTime: token,
        command: command == null || command.isEmpty ? null : command,
        created: created,
      ),
    );
  }
  return ProcessTable(out);
}

/// Fixed commands (no user input) that list the Windows process table.
const List<String> windowsPowerShellArgs = [
  '-NoProfile',
  '-NonInteractive',
  '-Command',
  'Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,'
      "@{n='Created';e={\$_.CreationDate.ToFileTimeUtc()}},CommandLine | "
      'ConvertTo-Csv -NoTypeInformation',
];
const List<String> windowsWmicArgs = [
  'process',
  'get',
  'ProcessId,ParentProcessId,CreationDate,CommandLine',
  '/format:csv',
];

Future<ProcessTable> _readWindowsTable() async {
  for (final attempt in [
    ('powershell', windowsPowerShellArgs),
    ('wmic', windowsWmicArgs),
  ]) {
    try {
      final result = await Process.run(attempt.$1, attempt.$2);
      if (result.exitCode != 0) continue;
      final table = parseWindowsProcessCsv(result.stdout as String);
      if (table.byPid.isNotEmpty) return table;
    } on ProcessException {
      // Not installed; try the next one.
    }
  }
  return const ProcessTable.empty();
}

/// Reads the process table: `ps -A -o pid=,ppid=,stat=,lstart=` (with a
/// `/proc` fallback on Linux) on POSIX, PowerShell/wmic CSV on Windows.
Future<ProcessTable> readProcessTable(HostEnvironment env) async {
  if (env.isWindows) return _readWindowsTable();
  try {
    final result = await Process.run(
      'ps',
      const ['-A', '-o', 'pid=,ppid=,stat=,lstart='],
      environment: const {'LC_ALL': 'C', 'LANG': 'C'},
    );
    if (result.exitCode == 0) {
      final table = parseProcessTable(result.stdout as String);
      if (table.byPid.isNotEmpty) return table;
    }
  } on ProcessException {
    // ps is missing; try /proc below.
  }
  if (env.os == HostOs.linux) return _readProc();
  return const ProcessTable.empty();
}

ProcessTable _readProc() {
  final rows = <ProcessInfo>[];
  try {
    for (final entity in Directory('/proc').listSync(followLinks: false)) {
      final name = entity.path.split('/').last;
      final pid = int.tryParse(name);
      if (pid == null) continue;
      try {
        final text = File('/proc/$pid/stat').readAsStringSync();
        final close = text.lastIndexOf(')');
        if (close < 0) continue;
        final f = text.substring(close + 1).trim().split(' ');
        // f[0]=state f[1]=ppid ... f[19]=starttime (field 22)
        if (f.length < 20) continue;
        final ppid = int.tryParse(f[1]);
        if (ppid == null) continue;
        rows.add(
          ProcessInfo(
            pid,
            ppid,
            startTime: f[19],
            zombie: f[0] == 'Z' || f[0] == 'X',
          ),
        );
      } on FileSystemException {
        // The process ended while we were reading.
      }
    }
  } on FileSystemException {
    return const ProcessTable.empty();
  }
  return ProcessTable(rows);
}

/// Command lines of [pids] (POSIX; empty map when they cannot be read).
Future<Map<int, String>> readCommandLines(
  Iterable<int> pids,
  HostEnvironment env,
) async {
  final wanted = pids.toSet();
  if (wanted.isEmpty) return const <int, String>{};
  if (env.isWindows) {
    final table = await readProcessTable(env);
    return {
      for (final pid in wanted)
        if (table.byPid[pid]?.command != null) pid: table.byPid[pid]!.command!,
    };
  }
  try {
    final result = await Process.run(
      'ps',
      ['-o', 'pid=,command=', '-p', wanted.join(',')],
      environment: const {'LC_ALL': 'C', 'LANG': 'C'},
    );
    return parseCommandLines(result.stdout as String);
  } on ProcessException {
    return const <int, String>{};
  }
}

/// Parses `pid command...` lines.
Map<int, String> parseCommandLines(String psOutput) {
  final out = <int, String>{};
  for (final raw in psOutput.split('\n')) {
    final line = raw.trim();
    final space = line.indexOf(RegExp(r'\s'));
    if (space < 0) continue;
    final pid = int.tryParse(line.substring(0, space));
    if (pid != null) out[pid] = line.substring(space).trim();
  }
  return out;
}

final RegExp _sharedDaemon = RegExp(
  r'(^|[\s/\\"])adb(\.exe)?("|\s|$)'
  r'|GradleDaemon|GradleWrapperMain|gradle-launcher|org\.gradle'
  r'|KotlinCompileDaemon|kotlin-daemon|kotlin-compiler'
  r'|tooling[-_]daemon|DartToolingDaemon',
  caseSensitive: false,
);

/// True for command lines of long-lived helpers shared with other projects
/// or editors (adb, Gradle and Kotlin daemons, the Dart tooling daemon).
/// These are never killed by the crash sweep.
bool isSharedDaemonCommand(String command) => _sharedDaemon.hasMatch(command);

typedef ProcessTableReader = Future<ProcessTable> Function();
typedef SignalSender = bool Function(int pid, ProcessSignal signal);
typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// Terminates [rootPid] and [snapshot] (pids that were its descendants).
///
/// POSIX: before each signal round the process table is re-read and only pids
/// that are provably ours are signalled: [rootPid], current descendants of
/// [rootPid], and snapshot pids whose start time in [startTimes] still matches
/// (they were reparented after their parent died). SIGTERM, then after [grace]
/// SIGKILL for survivors. Pids 0 and 1 are never signalled.
///
/// Windows: `taskkill /PID <root> /T /F` (and for every other snapshot pid).
Future<void> killTree(
  int rootPid,
  Set<int> snapshot,
  HostEnvironment env, {
  Duration grace = const Duration(seconds: 2),
  Map<int, String> startTimes = const <int, String>{},
  ProcessTableReader? readTable,
  SignalSender? sendSignal,
  ProcessRunner? runProcess,
}) async {
  final read = readTable ?? () => readProcessTable(env);
  final send = sendSignal ?? ((pid, signal) => Process.killPid(pid, signal));

  Future<Set<int>> eligible() async {
    final table = await read();
    final descendants = rootPid <= 1
        ? <int>{}
        : collectDescendants(table.childrenOf, rootPid);
    final out = <int>{};
    for (final pid in <int>{rootPid, ...snapshot, ...descendants}) {
      if (pid <= 1) continue;
      final info = table.byPid[pid];
      if (info == null || info.zombie) continue;
      final known = startTimes[pid];
      final sameInstance =
          known == null || info.startTime == null || known == info.startTime;
      if (pid == rootPid || descendants.contains(pid)) {
        if (sameInstance) out.add(pid);
      } else if (known != null && info.startTime == known) {
        // Was a descendant; the parent died and it was reparented.
        out.add(pid);
      }
    }
    return out;
  }

  if (env.isWindows) {
    final run = runProcess ?? ((e, a) => Process.run(e, a));
    Future<void> taskkill(int pid, {required bool tree}) async {
      try {
        await run('taskkill', ['/PID', '$pid', if (tree) '/T', '/F']);
      } on ProcessException {
        // taskkill missing or the process is gone.
      }
    }

    // With a readable process table only provably-ours pids are killed
    // (PID-reuse guard by creation date). /T is used for the root while it is
    // alive, so its tree goes with it.
    final first = await eligible();
    if (first.isEmpty && (await read()).byPid.isEmpty) {
      // No table (PowerShell and wmic unavailable): best effort by pid.
      for (final pid in <int>{rootPid, ...snapshot}) {
        if (pid > 4) await taskkill(pid, tree: true);
      }
      return;
    }
    var round = first;
    for (var i = 0; i < 3 && round.isNotEmpty; i++) {
      for (final pid in round) {
        if (pid > 4) await taskkill(pid, tree: pid == rootPid);
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      round = await eligible();
    }
    return;
  }

  var alive = await eligible();
  if (alive.isEmpty) return;
  for (final pid in alive) {
    send(pid, ProcessSignal.sigterm);
  }

  final deadline = DateTime.now().add(grace);
  while (true) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    alive = await eligible();
    if (alive.isEmpty) return;
    if (!DateTime.now().isBefore(deadline)) break;
  }
  for (final pid in alive) {
    send(pid, ProcessSignal.sigkill);
  }
  // Give the kernel a moment so callers observe the processes gone.
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    if ((await eligible()).isEmpty) return;
  }
}
