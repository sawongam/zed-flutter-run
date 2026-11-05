import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../common/files.dart';
import '../common/host_environment.dart';
import '../common/json_types.dart';
import '../common/logger.dart';
import 'control_client.dart';
import 'session_info.dart';
import 'session_paths.dart';

/// Owner-side handle on a session file.
class SessionHandle {
  SessionHandle._(this.path, this._env);

  /// Full path of the `<pid>.json` file.
  final String path;
  final HostEnvironment _env;
  Future<void> _tail = Future<void>.value();
  bool _deleted = false;

  /// Atomically rewrites the file. Calls are serialised; after [delete] they
  /// do nothing, so a late update cannot bring the file back.
  Future<void> update(SessionInfo info) {
    final next = _tail.then((_) async {
      if (_deleted) return;
      await atomicWriteString(
        path,
        '${jsonEncode(info.toJson())}\n',
        env: _env,
      );
    });
    _tail = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  /// Deletes the file (idempotent).
  Future<void> delete() {
    _deleted = true;
    final next = _tail.then((_) => _deleteFile(path, retries: 10));
    _tail = next;
    return next;
  }
}

Future<void> _deleteFile(String path, {int retries = 1}) async {
  for (var attempt = 1; ; attempt++) {
    try {
      final file = File(path);
      if (file.existsSync()) await file.delete();
      return;
    } on FileSystemException {
      if (!File(path).existsSync()) return;
      if (attempt >= retries) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

/// A session file read by [SessionStore.list].
class SessionRecord {
  const SessionRecord({
    required this.info,
    required this.unresponsive,
    required this.path,
  });

  final SessionInfo info;

  /// Connected, but no reply to the ping in time.
  final bool unresponsive;
  final String path;
}

/// Reads and writes the per-user session files.
class SessionStore {
  SessionStore(this._env, {Logger? logger, ControlClient? probe})
    : _logger = logger ?? Logger.silent(),
      _probe = probe ?? ControlClient();

  final HostEnvironment _env;
  final Logger _logger;
  final ControlClient _probe;

  /// Creates the sessions directory (mode 0700 on POSIX) and writes the file.
  Future<SessionHandle> create(SessionInfo info) async {
    final directory = sessionsDirectory(_env);
    await ensureOwnerOnlyDirectory(directory, _env);
    final handle = SessionHandle._(
      _env.pathContext.join(directory, sessionFileName(info.pid)),
      _env,
    );
    await handle.update(info);
    return handle;
  }

  /// Reads every session file and pings all of them concurrently. Stale ones
  /// are deleted (when [prune]) and left out; unresponsive ones are kept and
  /// flagged. Unreadable files and other schema versions are skipped. Sorted
  /// by start time, oldest first.
  Future<List<SessionRecord>> list({bool prune = true}) async {
    final directory = Directory(sessionsDirectory(_env));
    if (!directory.existsSync()) return const [];
    final candidates = <(String, SessionInfo)>[];
    try {
      for (final entity in directory.listSync(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        final info = _read(entity);
        if (info != null) candidates.add((entity.path, info));
      }
    } on FileSystemException catch (e) {
      _logger.debug('Could not list session files: ${e.message}');
      return const [];
    }
    final records = await Future.wait(
      candidates.map((c) async {
        final outcome = await _probe.ping(c.$2);
        if (outcome == PingOutcome.stale) {
          _logger.debug('Session file ${c.$1} is stale.');
          if (prune) await _deleteIfUnchanged(c.$1, c.$2);
          return null;
        }
        return SessionRecord(
          info: c.$2,
          unresponsive: outcome == PingOutcome.unresponsive,
          path: c.$1,
        );
      }),
    );
    return [for (final record in records) ?record]
      ..sort((a, b) => a.info.startedAt.compareTo(b.info.startedAt));
  }

  /// Deletes [path] only if it still holds the session we pinged (a new
  /// process may have reused the pid and rewritten the file meanwhile).
  Future<void> _deleteIfUnchanged(String path, SessionInfo pinged) async {
    final current = _read(File(path));
    if (current == null) return;
    if (current.token != pinged.token || current.pid != pinged.pid) return;
    await _deleteFile(path);
  }

  SessionInfo? _read(File file) {
    try {
      final decoded = jsonDecode(_readText(file));
      if (decoded is! Json) {
        _logger.debug('Skipping ${file.path}: not a JSON object.');
        return null;
      }
      return SessionInfo.fromJson(decoded);
    } on FormatException catch (e) {
      _logger.debug('Skipping ${file.path}: ${e.message}');
    } on FileSystemException catch (e) {
      _logger.debug('Skipping ${file.path}: ${e.message}');
    }
    return null;
  }
}

/// Reads [file], retrying briefly on a sharing violation: on Windows a read
/// can collide with the owner's atomic rename of a new version.
String _readText(File file) {
  for (var attempt = 1; ; attempt++) {
    try {
      return file.readAsStringSync();
    } on FileSystemException {
      if (attempt >= 5 || !file.existsSync()) rethrow;
      sleep(const Duration(milliseconds: 20));
    }
  }
}
