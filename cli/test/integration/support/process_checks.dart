import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// True while [pid] exists and is not a zombie.
bool isAlive(int pid) {
  if (Platform.isWindows) {
    final r = Process.runSync('tasklist', [
      '/FI',
      'PID eq $pid',
      '/NH',
      '/FO',
      'CSV',
    ]);
    return (r.stdout as String).contains('"$pid"');
  }
  if (Platform.isLinux) {
    try {
      final stat = File('/proc/$pid/stat').readAsStringSync();
      final state = stat.substring(
        stat.lastIndexOf(')') + 2,
        stat.lastIndexOf(')') + 3,
      );
      return state != 'Z' && state != 'X';
    } on FileSystemException {
      return false;
    }
  }
  final r = Process.runSync('ps', ['-o', 'stat=', '-p', '$pid']);
  final stat = (r.stdout as String).trim();
  return r.exitCode == 0 && stat.isNotEmpty && !stat.startsWith('Z');
}

/// All (pid, ppid) pairs of the machine.
Future<Map<int, int>> _parentTable() async {
  final table = <int, int>{};
  if (Platform.isWindows) {
    // Windows keeps the stale parent pid of orphans, and pids are reused, so
    // an unrelated process (winlogon.exe, dwm.exe, ...) can look like a child
    // of a new process. A real child is never created before its parent.
    final r = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      r'Get-CimInstance Win32_Process | ForEach-Object { "$($_.ProcessId) $($_.ParentProcessId) $($_.CreationDate.ToFileTimeUtc())" }',
    ]);
    final parents = <int, int>{};
    final created = <int, int>{};
    for (final line in LineSplitter.split(r.stdout as String)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length == 3) {
        final pid = int.tryParse(parts[0]);
        final ppid = int.tryParse(parts[1]);
        final at = int.tryParse(parts[2]);
        if (pid != null && ppid != null && at != null) {
          parents[pid] = ppid;
          created[pid] = at;
        }
      }
    }
    parents.forEach((pid, ppid) {
      final parentAt = created[ppid];
      if (parentAt == null || created[pid]! >= parentAt) table[pid] = ppid;
    });
    return table;
  }
  final r = await Process.run('ps', ['-eo', 'pid=,ppid=']);
  for (final line in LineSplitter.split(r.stdout as String)) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length == 2) {
      final pid = int.tryParse(parts[0]);
      final ppid = int.tryParse(parts[1]);
      if (pid != null && ppid != null) table[pid] = ppid;
    }
  }
  return table;
}

/// Direct children of [parent].
Future<Set<int>> childrenOf(int parent) async {
  final table = await _parentTable();
  return {
    for (final e in table.entries)
      if (e.value == parent) e.key,
  };
}

/// Every live descendant of [root] (children, grandchildren, ...).
Future<Set<int>> descendantsOf(int root) async {
  final table = await _parentTable();
  final children = <int, List<int>>{};
  table.forEach((pid, ppid) => children.putIfAbsent(ppid, () => []).add(pid));
  final out = <int>{};
  void walk(int p) {
    for (final c in children[p] ?? const <int>[]) {
      if (out.add(c)) walk(c);
    }
  }

  walk(root);
  return out;
}

/// Command lines of [pids], for failure messages and role checks.
Future<Map<int, String>> commandLines(Iterable<int> pids) async {
  final out = <int, String>{};
  for (final pid in pids) {
    if (Platform.isWindows) {
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        '(Get-CimInstance Win32_Process -Filter "ProcessId=$pid").CommandLine',
      ]);
      out[pid] = (r.stdout as String).trim();
    } else if (Platform.isLinux) {
      try {
        out[pid] = File(
          '/proc/$pid/cmdline',
        ).readAsStringSync().replaceAll('\u0000', ' ').trim();
      } on FileSystemException {
        out[pid] = '';
      }
    } else {
      final r = await Process.run('ps', ['-o', 'args=', '-p', '$pid']);
      out[pid] = (r.stdout as String).trim();
    }
  }
  return out;
}

/// Kills [pids] hard. Best effort; already dead processes are ignored.
void killAll(Iterable<int> pids) {
  for (final pid in pids) {
    if (!isAlive(pid)) continue;
    if (Platform.isWindows) {
      Process.runSync('taskkill', ['/PID', '$pid', '/T', '/F']);
    } else {
      Process.killPid(pid, ProcessSignal.sigkill);
    }
  }
}

/// Waits until none of [pids] is alive (zombies count as dead). On timeout the
/// survivors are killed and the test fails with their command lines.
Future<void> expectAllGone(
  Iterable<int> pids, {
  Duration timeout = const Duration(seconds: 15),
  String what = 'processes',
  String Function()? context,
}) async {
  final all = pids.toSet();
  final deadline = DateTime.now().add(timeout);
  var alive = <int>[];
  while (true) {
    alive = [
      for (final p in all)
        if (isAlive(p)) p,
    ];
    if (alive.isEmpty) return;
    if (DateTime.now().isAfter(deadline)) break;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  final lines = await commandLines(alive);
  killAll(alive);
  fail(
    'Orphaned $what still alive after ${timeout.inSeconds} s:\n'
    '${lines.entries.map((e) => '  ${e.key}: ${e.value}').join('\n')}'
    '${context == null ? '' : '\n${context()}'}',
  );
}

/// Waits until [pid] is gone; fails with [what] otherwise.
Future<void> expectGone(int pid, String what, {Duration? timeout}) =>
    expectAllGone(
      [pid],
      what: what,
      timeout: timeout ?? const Duration(seconds: 15),
    );
