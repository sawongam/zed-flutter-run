import 'dart:async';
import 'dart:io';

import 'package:watcher/watcher.dart';

import '../common/host_environment.dart';
import '../common/logger.dart';
import '../common/paths.dart';
import 'coalescer.dart';
import 'content_hash.dart';
import 'path_filter.dart';
import 'reload_config.dart';

/// Result of the injected reload action.
class ReloadOutcome {
  const ReloadOutcome({
    required this.ok,
    this.busy = false,
    this.message,
    this.joined = false,
  });

  final bool ok;
  final bool busy;

  /// True when the reload joined one that was already running, so the saved
  /// content may not have been applied. The watcher then runs exactly one
  /// more reload.
  final bool joined;
  final String? message;
}

/// Watches the allow-listed directories and hot reloads on save.
class ReloadOnSaveWatcher {
  ReloadOnSaveWatcher({
    required String projectRoot,
    required bool isDartProgram,
    required ReloadOnSaveConfig config,
    required HostEnvironment env,
    required Future<ReloadOutcome> Function() reload,
    required void Function(String text, {required bool isError}) notice,
    Logger? logger,
    Stream<WatchEvent> Function(String directory)? watcherFactory,
  }) : _projectRoot = projectRoot,
       _isDartProgram = isDartProgram,
       _config = config,
       _env = env,
       _reload = reload,
       _notice = notice,
       _logger = logger ?? Logger.silent(),
       _watcherFactory = watcherFactory;

  final String _projectRoot;
  final bool _isDartProgram;
  final ReloadOnSaveConfig _config;
  final HostEnvironment _env;
  final Future<ReloadOutcome> Function() _reload;
  final void Function(String text, {required bool isError}) _notice;
  final Logger _logger;
  final Stream<WatchEvent> Function(String directory)? _watcherFactory;

  ContentHashTracker _hashes = ContentHashTracker();
  final List<StreamSubscription<WatchEvent>> _subscriptions = [];
  final List<String> _watched = [];
  final List<String> _changedPaths = [];
  final Map<String, String> _changedKeys = {};
  final Map<String, String> _changedAbs = {};
  final Map<String, String> _applied = {};
  late PathFilter _filter;
  ReloadCoalescer? _coalescer;
  Future<void> _queue = Future<void>.value();
  bool _running = false;
  bool _noticeShown = false;
  bool _joinRetried = false;

  bool get running => _running;
  List<String> get watchedDirectories => List.unmodifiable(_watched);

  /// How long [start] waits for the native watchers to become ready.
  static const Duration _readyTimeout = Duration(seconds: 10);

  Future<void> start() async {
    if (_running || _config.mode == ReloadOnSaveMode.off) return;
    for (final warning in _config.warnings) {
      _notice(warning, isError: false);
    }

    final rejected = <String>[];
    final candidates = PathFilter.watchDirectories(
      projectRoot: _projectRoot,
      isDartProgram: _isDartProgram,
      globs: _config.globs,
      env: _env,
      rejectedGlobs: rejected,
    );
    for (final glob in rejected) {
      _notice(
        'Warning: The reload on save pattern "$glob" does not name a folder '
        'to watch. Start it with a folder, for example "assets/**.json".',
        isError: false,
      );
    }
    final accepted = [
      for (final g in _config.globs)
        if (!rejected.contains(g)) g,
    ];
    _filter = PathFilter(projectRoot: _projectRoot, env: _env, globs: accepted);

    final dirs = candidates.where((d) => Directory(d).existsSync()).toList();
    if (dirs.isEmpty) {
      _notice(
        'Warning: Reload on save found no folder to watch in the project. '
        'Create a lib/ folder or add "reloadOnSaveGlobs" in .zed/debug.json.',
        isError: false,
      );
      return;
    }

    _coalescer = ReloadCoalescer(
      debounce: _config.debounce,
      reload: _runReload,
      onError: (e, st) {
        _logger.error('Reload on save failed', e, st);
        _notice('Error: Hot reload failed: $e.', isError: true);
      },
    );

    final ready = <Future<void>>[];
    for (final dir in dirs) {
      final factory = _watcherFactory;
      Stream<WatchEvent> events;
      if (factory != null) {
        events = factory(dir);
      } else {
        final watcher = DirectoryWatcher(dir);
        ready.add(watcher.ready);
        events = watcher.events;
      }
      _subscriptions.add(
        events.listen(
          _onEvent,
          onError: (Object e, StackTrace st) =>
              _logger.warn('File watcher error in $dir: $e'),
        ),
      );
      _watched.add(dir);
    }
    _running = true;
    if (_config.mode == ReloadOnSaveMode.changed) {
      // A cheap baseline of the files already present: late events from
      // setup work (or an editor rewriting identical bytes) then do not count
      // as changes. Events are handled after it completes.
      _queue = _queue.then((_) => _baseline(dirs));
      await _queue;
    }

    final what = _config.mode == ReloadOnSaveMode.always
        ? 'every save'
        : 'changed files only';
    final names = _watched.map((d) => '${_display(d)}/').join(', ');
    _notice(
      'Reload on save is on for $names ($what). Set "reloadOnSave": "off" in '
      '.zed/debug.json to turn it off. With Zed autosave enabled, every '
      'autosave reloads.',
      isError: false,
    );

    if (ready.isNotEmpty) {
      try {
        await Future.wait(ready).timeout(_readyTimeout);
      } on Object catch (e) {
        _logger.warn('File watcher was not ready in time: $e');
      }
    }
  }

  Future<void> stop() async {
    _running = false;
    final coalescer = _coalescer;
    _coalescer = null;
    final subs = List.of(_subscriptions);
    _subscriptions.clear();
    for (final s in subs) {
      await s.cancel();
    }
    await coalescer?.dispose();
    await _queue;
    _watched.clear();
    _changedPaths.clear();
    _changedKeys.clear();
    _changedAbs.clear();
    _applied.clear();
    _noticeShown = false;
    _joinRetried = false;
    _hashes = ContentHashTracker();
  }

  String _display(String dir) =>
      _filter.relativePath(dir) ?? dir.replaceAll('\\', '/');

  Future<void> _baseline(List<String> dirs) async {
    var count = 0;
    for (final dir in dirs) {
      try {
        await for (final entity in Directory(
          dir,
        ).list(recursive: true, followLinks: false)) {
          if (!_running || count >= _maxBaselineFiles) return;
          if (entity is! File || !_filter.shouldTrigger(entity.path)) continue;
          count++;
          await _hashes.hasChanged(
            entity.path,
            key: pathKey(entity.path, _env),
          );
        }
      } on Object catch (e) {
        _logger.debug('Reload on save baseline skipped for $dir: $e');
      }
    }
  }

  static const int _maxBaselineFiles = 20000;

  void _onEvent(WatchEvent event) {
    if (!_running) return;
    // Handle events one at a time so hashes are compared in order.
    _queue = _queue.then((_) => _handle(event)).catchError((Object e) {
      _logger.warn('Could not process file event for ${event.path}: $e');
    });
  }

  Future<void> _handle(WatchEvent event) async {
    if (!_running || !_filter.shouldTrigger(event.path)) return;
    if (_config.mode == ReloadOnSaveMode.changed) {
      final changed = await _hashes.hasChanged(
        event.path,
        key: pathKey(event.path, _env),
      );
      if (!changed) return;
    }
    if (!_running) return;
    final relative = _filter.relativePath(event.path) ?? event.path;
    if (!_changedPaths.contains(relative)) _changedPaths.add(relative);
    _changedKeys[relative] = pathKey(event.path, _env);
    _changedAbs[relative] = event.path;
    _coalescer?.notifyChange();
  }

  Future<ReloadResult> _runReload() async {
    final paths = List.of(_changedPaths);
    _changedPaths.clear();

    // Content this reload will apply. If every file already has exactly that
    // content from an earlier reload (a follow-up caused by a half-written
    // read or an identical rewrite), there is nothing to do.
    final digests = <String, String>{};
    if (_config.mode == ReloadOnSaveMode.changed) {
      var allApplied = paths.isNotEmpty;
      for (final p in paths) {
        final key = _changedKeys[p];
        final abs = _changedAbs[p];
        final d = abs == null ? null : await _hashes.digest(abs);
        if (key == null || d == null) {
          allApplied = false;
          continue;
        }
        digests[key] = d;
        if (_applied[key] != d) allApplied = false;
      }
      if (allApplied && !_joinRetried) {
        _noticeShown = false;
        for (final p in paths) {
          if (!_changedPaths.contains(p)) {
            _changedKeys.remove(p);
            _changedAbs.remove(p);
          }
        }
        return ReloadResult.done;
      }
      _applied.addAll(digests);
    }

    if (!_noticeShown && paths.isNotEmpty) {
      final more = paths.length - 1;
      _notice(
        'Hot reload on save: ${paths.first}'
        '${more > 0 ? ' (+$more more)' : ''}',
        isError: false,
      );
      _noticeShown = true;
    }
    void forgetBatch() {
      for (final p in paths) {
        final key = _changedKeys[p];
        if (key != null) {
          _hashes.forget(key);
          _applied.remove(key);
        }
      }
    }

    final ReloadOutcome outcome;
    try {
      outcome = await _reload();
    } on Object {
      // Let the same content be saved again to retry; show the next notice.
      _noticeShown = false;
      forgetBatch();
      rethrow;
    }
    if (outcome.busy) {
      // Keep the files for the retry; the notice was already printed.
      for (final p in paths) {
        final key = _changedKeys[p];
        if (key != null) _applied.remove(key);
      }
      for (final p in paths.reversed) {
        if (!_changedPaths.contains(p)) _changedPaths.insert(0, p);
      }
      return ReloadResult.busy;
    }
    if (outcome.ok && outcome.joined && !_joinRetried && _running) {
      // The reload joined an earlier one that may have compiled before these
      // saves: run exactly one more, with the same files and no new notice.
      _joinRetried = true;
      for (final p in paths.reversed) {
        if (!_changedPaths.contains(p)) _changedPaths.insert(0, p);
      }
      _coalescer?.notifyChange();
      return ReloadResult.done;
    }
    _joinRetried = false;
    _noticeShown = false;
    if (!outcome.ok) {
      forgetBatch();
      if (_running) {
        final message = outcome.message;
        _notice(
          'Error: Hot reload failed${message == null ? '' : ': $message'}. '
          'Try the task "Flutter: Hot Restart".',
          isError: true,
        );
      }
    }
    for (final p in paths) {
      if (!_changedPaths.contains(p)) {
        _changedKeys.remove(p);
        _changedAbs.remove(p);
      }
    }
    return ReloadResult.done;
  }
}
