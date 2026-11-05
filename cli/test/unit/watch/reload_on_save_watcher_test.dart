import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_run/src/common/host_environment.dart';
import 'package:flutter_run/src/watch/reload_config.dart';
import 'package:flutter_run/src/watch/reload_on_save_watcher.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:watcher/watcher.dart';

const _fast = Duration(milliseconds: 20);

/// Polls until [condition] holds or the timeout passes.
Future<void> eventually(
  bool Function() condition, {
  String reason = 'condition',
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for $reason.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory tmp;
  late String root;
  late HostEnvironment env;
  late List<String> notices;
  late List<bool> noticeErrors;
  late int reloads;
  late ReloadOutcome Function() outcome;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('flutter_run_watch_');
    root = Directory(tmp.path).resolveSymbolicLinksSync();
    env = HostEnvironment.system();
    notices = [];
    noticeErrors = [];
    reloads = 0;
    outcome = () => const ReloadOutcome(ok: true);
    Directory(p.join(root, 'lib')).createSync();
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  ReloadOnSaveWatcher make({
    ReloadOnSaveMode mode = ReloadOnSaveMode.changed,
    List<String> globs = const [],
    bool dart = false,
    Duration debounce = _fast,
    Stream<WatchEvent> Function(String)? factory,
  }) => ReloadOnSaveWatcher(
    projectRoot: root,
    isDartProgram: dart,
    config: ReloadOnSaveConfig(mode: mode, globs: globs, debounce: debounce),
    env: env,
    reload: () async {
      reloads++;
      return outcome();
    },
    notice: (text, {required isError}) {
      notices.add(text);
      noticeErrors.add(isError);
    },
    watcherFactory: factory,
  );

  group('with a fake watcher factory', () {
    late Map<String, StreamController<WatchEvent>> controllers;
    late List<String> factoryCalls;

    Stream<WatchEvent> fakeFactory(String dir) {
      factoryCalls.add(dir);
      return (controllers[dir] = StreamController<WatchEvent>.broadcast())
          .stream;
    }

    void emit(
      String dir,
      String relative, [
      ChangeType type = ChangeType.MODIFY,
    ]) {
      controllers[dir]!.add(WatchEvent(type, p.join(root, relative)));
    }

    setUp(() {
      controllers = {};
      factoryCalls = [];
    });

    test('only allow-listed existing directories get watchers', () async {
      for (final d in [
        'bin',
        'assets',
        'ios/Pods',
        'build',
        'android/.gradle',
      ]) {
        Directory(p.join(root, d)).createSync(recursive: true);
      }
      final w = make(
        globs: ['assets/**.json', 'missing/*.x', '**.json'],
        dart: false,
        factory: fakeFactory,
      );
      await w.start();
      expect(factoryCalls, [p.join(root, 'lib'), p.join(root, 'assets')]);
      expect(w.watchedDirectories, factoryCalls);
      expect(w.running, isTrue);
      await w.stop();
      expect(w.running, isFalse);
    });

    test('bin is watched for Dart programs', () async {
      Directory(p.join(root, 'bin')).createSync();
      final w = make(dart: true, factory: fakeFactory);
      await w.start();
      expect(factoryCalls, [p.join(root, 'lib'), p.join(root, 'bin')]);
      await w.stop();
    });

    test('armed notice names the directories; rejected glob warns', () async {
      Directory(p.join(root, 'assets')).createSync();
      final w = make(globs: ['assets/*.json', '**.json'], factory: fakeFactory);
      await w.start();
      final armed = notices.firstWhere(
        (n) => n.startsWith('Reload on save is on'),
      );
      expect(
        armed,
        startsWith(
          'Reload on save is on for lib/, assets/ (changed files only).',
        ),
      );
      expect(armed, contains('"reloadOnSave": "off"'));
      expect(
        notices.where((n) => n.startsWith('Reload on save is on')),
        hasLength(1),
      );
      expect(
        notices.any((n) => n.startsWith('Warning:') && n.contains('**.json')),
        isTrue,
      );
      await w.stop();
    });

    test('mode off starts nothing', () async {
      final w = make(mode: ReloadOnSaveMode.off, factory: fakeFactory);
      await w.start();
      expect(factoryCalls, isEmpty);
      expect(notices, isEmpty);
      expect(w.running, isFalse);
    });

    test('no directory to watch warns and does not run', () async {
      Directory(p.join(root, 'lib')).deleteSync();
      final w = make(factory: fakeFactory);
      await w.start();
      expect(w.running, isFalse);
      expect(notices.single, startsWith('Warning:'));
    });

    test(
      'changed mode skips an identical rewrite after the first event',
      () async {
        final file = File(p.join(root, 'lib', 'a.dart'))
          ..writeAsStringSync('v0');
        final w = make(factory: fakeFactory);
        await w.start();
        final lib = p.join(root, 'lib');
        file.writeAsStringSync('v1');
        emit(lib, 'lib/a.dart');
        await eventually(() => reloads == 1, reason: 'first reload');
        emit(lib, 'lib/a.dart');
        emit(lib, 'lib/a.dart');
        await Future<void>.delayed(_fast * 6);
        expect(reloads, 1);
        file.writeAsStringSync('v2');
        emit(lib, 'lib/a.dart');
        await eventually(() => reloads == 2, reason: 'second reload');
        expect(notices, contains('Hot reload on save: lib/a.dart'));
        await w.stop();
      },
    );

    test('always mode reloads for identical rewrites', () async {
      File(p.join(root, 'lib', 'a.dart')).writeAsStringSync('v1');
      final w = make(mode: ReloadOnSaveMode.always, factory: fakeFactory);
      await w.start();
      final lib = p.join(root, 'lib');
      emit(lib, 'lib/a.dart');
      await eventually(() => reloads == 1);
      emit(lib, 'lib/a.dart');
      await eventually(() => reloads == 2);
      expect(notices.first, contains('every save'));
      await w.stop();
    });

    test('ignored and non-matching files never reload', () async {
      final w = make(mode: ReloadOnSaveMode.always, factory: fakeFactory);
      await w.start();
      final lib = p.join(root, 'lib');
      emit(lib, 'lib/readme.md');
      emit(lib, 'lib/.a.dart.swp');
      emit(lib, 'lib/a.dart~');
      emit(lib, 'lib/.hidden/a.dart');
      emit(lib, 'lib/.dart_tool/a.dart');
      await Future<void>.delayed(_fast * 6);
      expect(reloads, 0);
      await w.stop();
    });

    test('notice format for several files', () async {
      for (final n in ['a', 'b', 'c']) {
        File(p.join(root, 'lib', '$n.dart')).writeAsStringSync(n);
      }
      final w = make(factory: fakeFactory);
      await w.start();
      final lib = p.join(root, 'lib');
      for (final n in ['a', 'b', 'c']) {
        File(p.join(root, 'lib', '$n.dart')).writeAsStringSync('$n$n');
      }
      emit(lib, 'lib/a.dart');
      emit(lib, 'lib/b.dart');
      emit(lib, 'lib/c.dart');
      await eventually(() => reloads == 1);
      expect(notices, contains('Hot reload on save: lib/a.dart (+2 more)'));
      await w.stop();
    });

    test(
      'failure gives an error notice and the watcher keeps running',
      () async {
        final file = File(p.join(root, 'lib', 'a.dart'))
          ..writeAsStringSync('1');
        outcome = () => const ReloadOutcome(ok: false, message: 'Syntax error');
        final w = make(factory: fakeFactory);
        await w.start();
        final lib = p.join(root, 'lib');
        file.writeAsStringSync('x');
        emit(lib, 'lib/a.dart');
        await eventually(
          () => noticeErrors.contains(true),
          reason: 'error notice',
        );
        final error = notices[noticeErrors.indexOf(true)];
        expect(error, startsWith('Error: Hot reload failed: Syntax error.'));
        expect(error, contains('Flutter: Hot Restart'));
        expect(w.running, isTrue);
        outcome = () => const ReloadOutcome(ok: true);
        file.writeAsStringSync('2');
        emit(lib, 'lib/a.dart');
        await eventually(() => reloads == 2);
        await w.stop();
      },
    );

    test('busy outcome retries without an error notice', () async {
      File(p.join(root, 'lib', 'a.dart')).writeAsStringSync('1');
      var n = 0;
      outcome = () => ++n < 3
          ? const ReloadOutcome(ok: false, busy: true)
          : const ReloadOutcome(ok: true);
      final w = make(factory: fakeFactory);
      await w.start();
      File(p.join(root, 'lib', 'a.dart')).writeAsStringSync('2');
      emit(p.join(root, 'lib'), 'lib/a.dart');
      await eventually(() => n >= 3, reason: 'retries');
      await Future<void>.delayed(_fast * 4);
      expect(noticeErrors.contains(true), isFalse);
      expect(
        notices.where((x) => x.startsWith('Hot reload on save')),
        hasLength(1),
      );
      await w.stop();
    });

    test('a throwing reload does not suppress later notices', () async {
      File(p.join(root, 'lib', 'a.dart')).writeAsStringSync('1');
      var n = 0;
      final w = ReloadOnSaveWatcher(
        projectRoot: root,
        isDartProgram: false,
        config: const ReloadOnSaveConfig(
          mode: ReloadOnSaveMode.always,
          debounce: _fast,
        ),
        env: env,
        reload: () async {
          if (++n == 1) throw StateError('boom');
          return const ReloadOutcome(ok: true);
        },
        notice: (t, {required isError}) => notices.add(t),
        watcherFactory: fakeFactory,
      );
      await w.start();
      final lib = p.join(root, 'lib');
      emit(lib, 'lib/a.dart');
      await eventually(() => n == 1);
      await Future<void>.delayed(_fast * 3);
      emit(lib, 'lib/a.dart');
      await eventually(() => n == 2);
      expect(
        notices.where((x) => x == 'Hot reload on save: lib/a.dart'),
        hasLength(2),
      );
      await w.stop();
    });

    test('a failed reload lets identical content retry', () async {
      File(p.join(root, 'lib', 'a.dart')).writeAsStringSync('old');
      outcome = () => const ReloadOutcome(ok: false, message: 'nope');
      final w = make(factory: fakeFactory);
      await w.start();
      final lib = p.join(root, 'lib');
      File(p.join(root, 'lib', 'a.dart')).writeAsStringSync('same');
      emit(lib, 'lib/a.dart');
      await eventually(() => reloads == 1);
      await Future<void>.delayed(_fast * 3);
      emit(lib, 'lib/a.dart');
      await eventually(() => reloads == 2, reason: 'retry of same content');
      outcome = () => const ReloadOutcome(ok: true);
      emit(lib, 'lib/a.dart');
      await eventually(() => reloads == 3);
      await Future<void>.delayed(_fast * 3);
      emit(lib, 'lib/a.dart');
      await Future<void>.delayed(_fast * 5);
      expect(reloads, 3);
      await w.stop();
    });

    test('start, stop, start works without duplicates', () async {
      final w = make(factory: fakeFactory);
      await w.start();
      await w.stop();
      expect(w.watchedDirectories, isEmpty);
      await w.start();
      expect(w.watchedDirectories, [p.join(root, 'lib')]);
      expect(
        notices.where((n) => n.startsWith('Reload on save is on for lib/ (')),
        hasLength(2),
      );
      File(p.join(root, 'lib', 'a.dart')).writeAsStringSync('1');
      emit(p.join(root, 'lib'), 'lib/a.dart');
      await eventually(() => reloads == 1);
      await w.stop();
    });

    test('events for files unchanged since arming do not reload', () async {
      File(p.join(root, 'lib', 'a.dart')).writeAsStringSync('same');
      final w = make(factory: fakeFactory);
      await w.start();
      final lib = p.join(root, 'lib');
      emit(lib, 'lib/a.dart');
      emit(lib, 'lib/a.dart', ChangeType.ADD);
      await Future<void>.delayed(_fast * 6);
      expect(reloads, 0);
      File(p.join(root, 'lib', 'a.dart')).writeAsStringSync('different');
      emit(lib, 'lib/a.dart');
      await eventually(() => reloads == 1);
      await w.stop();
    });

    test('a late event for applied content does not reload again', () async {
      final file = File(p.join(root, 'lib', 'a.dart'))..writeAsStringSync('0');
      final gate = Completer<void>();
      final w = ReloadOnSaveWatcher(
        projectRoot: root,
        isDartProgram: false,
        config: const ReloadOnSaveConfig(debounce: _fast),
        env: env,
        reload: () async {
          reloads++;
          await gate.future;
          return const ReloadOutcome(ok: true);
        },
        notice: (t, {required isError}) => notices.add(t),
        watcherFactory: fakeFactory,
      );
      await w.start();
      final lib = p.join(root, 'lib');
      file.writeAsStringSync('final');
      emit(lib, 'lib/a.dart');
      await eventually(() => reloads == 1);
      // A second event of the same save arrives while the reload runs; the
      // content is the one being applied.
      file.writeAsStringSync('');
      emit(lib, 'lib/a.dart');
      await Future<void>.delayed(_fast * 3);
      file.writeAsStringSync('final');
      emit(lib, 'lib/a.dart');
      await Future<void>.delayed(_fast * 3);
      gate.complete();
      await Future<void>.delayed(_fast * 8);
      expect(reloads, 1);
      await w.stop();
    });

    test('events after stop are ignored', () async {
      final w = make(mode: ReloadOnSaveMode.always, factory: fakeFactory);
      await w.start();
      final lib = p.join(root, 'lib');
      final controller = controllers[lib]!;
      await w.stop();
      controller.add(WatchEvent(ChangeType.MODIFY, p.join(lib, 'a.dart')));
      await Future<void>.delayed(_fast * 4);
      expect(reloads, 0);
    });
  });

  group('slow and joined reloads (fake time)', () {
    ReloadOnSaveWatcher fakeTimeWatcher(
      StreamController<WatchEvent> events,
      Future<ReloadOutcome> Function() reload,
    ) => ReloadOnSaveWatcher(
      projectRoot: root,
      isDartProgram: false,
      config: const ReloadOnSaveConfig(
        mode: ReloadOnSaveMode.always,
        debounce: _fast,
      ),
      env: env,
      reload: reload,
      notice: (t, {required isError}) {
        notices.add(t);
        noticeErrors.add(isError);
      },
      watcherFactory: (_) => events.stream,
    );

    WatchEvent save(String name) =>
        WatchEvent(ChangeType.MODIFY, p.join(root, 'lib', name));

    test('a paused reload raises no error and one follow-up runs', () {
      fakeAsync((async) {
        final events = StreamController<WatchEvent>.broadcast(sync: true);
        final pending = <Completer<ReloadOutcome>>[];
        final w = fakeTimeWatcher(events, () {
          final c = Completer<ReloadOutcome>();
          pending.add(c);
          return c.future;
        });
        w.start();
        async.flushMicrotasks();
        events.add(save('a.dart'));
        async.elapse(_fast * 2);
        expect(pending, hasLength(1));
        // The user sits at a breakpoint for ten minutes and saves again.
        for (var i = 0; i < 5; i++) {
          events.add(save('b.dart'));
          async.elapse(const Duration(minutes: 2));
        }
        expect(noticeErrors.contains(true), isFalse);
        expect(pending, hasLength(1));
        pending[0].complete(const ReloadOutcome(ok: true));
        async.flushMicrotasks();
        expect(pending, hasLength(2));
        pending[1].complete(const ReloadOutcome(ok: true));
        async.elapse(const Duration(seconds: 30));
        expect(pending, hasLength(2));
        expect(noticeErrors.contains(true), isFalse);
      });
    });

    test('a reload that joined an earlier one is repeated exactly once', () {
      fakeAsync((async) {
        final events = StreamController<WatchEvent>.broadcast(sync: true);
        var n = 0;
        final w = fakeTimeWatcher(events, () async {
          n++;
          return const ReloadOutcome(ok: true, joined: true);
        });
        w.start();
        async.flushMicrotasks();
        events.add(save('a.dart'));
        async.elapse(_fast * 2);
        async.elapse(const Duration(seconds: 30));
        expect(n, 2);
        expect(
          notices.where((x) => x.startsWith('Hot reload on save')),
          hasLength(1),
        );
        // A later independent save is handled again.
        events.add(save('a.dart'));
        async.elapse(const Duration(seconds: 30));
        expect(n, 4);
      });
    });
  });

  group('with the real file system', () {
    late ReloadOnSaveWatcher watcher;
    late String lib;

    setUp(() async {
      lib = p.join(root, 'lib');
    });

    tearDown(() async {
      await watcher.stop();
    });

    Future<void> startWatcher({
      ReloadOnSaveMode mode = ReloadOnSaveMode.changed,
    }) async {
      watcher = make(mode: mode);
      await watcher.start();
    }

    /// Runs [save] repeatedly until a reload was seen (the OS watcher may
    /// start a moment late); every attempt changes the content.
    Future<void> saveUntilReload(
      Future<void> Function(int attempt) save, {
      Duration window = const Duration(milliseconds: 300),
    }) async {
      final before = reloads;
      var attempt = 0;
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (reloads == before) {
        if (DateTime.now().isAfter(deadline)) fail('No reload after saving.');
        await save(attempt++);
        final inner = DateTime.now().add(window);
        while (reloads == before && DateTime.now().isBefore(inner)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }
    }

    test('in-place write', () async {
      final file = File(p.join(lib, 'a.dart'))..writeAsStringSync('0');
      await startWatcher();
      await saveUntilReload((i) async => file.writeAsStringSync('v$i'));
      expect(notices, contains('Hot reload on save: lib/a.dart'));
    });

    test('truncate then write', () async {
      final file = File(p.join(lib, 'a.dart'))..writeAsStringSync('0');
      await startWatcher();
      await saveUntilReload((i) async {
        final raf = file.openSync(mode: FileMode.write);
        raf.writeStringSync('t$i');
        raf.closeSync();
      });
    });

    test('atomic rename over the target', () async {
      final file = File(p.join(lib, 'a.dart'))..writeAsStringSync('0');
      await startWatcher();
      await saveUntilReload((i) async {
        final temp = File(p.join(lib, '.a.dart.tmp$i'))
          ..writeAsStringSync('r$i');
        temp.renameSync(file.path);
      });
      expect(notices.any((n) => n.contains('.tmp')), isFalse);
    });

    test('delete then create', () async {
      final file = File(p.join(lib, 'a.dart'))..writeAsStringSync('0');
      await startWatcher();
      await saveUntilReload((i) async {
        if (file.existsSync()) file.deleteSync();
        file.writeAsStringSync('d$i');
      });
    });

    test('editor temp and backup files do not reload', () async {
      await startWatcher(mode: ReloadOnSaveMode.always);
      for (final name in [
        'a.dart~',
        '.a.dart.swp',
        '4913',
        'a.dart.bak',
        '.#a.dart',
        'notes.md',
      ]) {
        File(p.join(lib, name)).writeAsStringSync('x');
      }
      // A real change afterwards proves the watcher is live.
      final marker = File(p.join(lib, 'marker.dart'));
      await saveUntilReload((i) async => marker.writeAsStringSync('m$i'));
      expect(
        notices.where((n) => n.startsWith('Hot reload on save: ')).first,
        'Hot reload on save: lib/marker.dart',
      );
    });

    test('a burst of 200 files (git checkout) reloads once or twice', () async {
      watcher = make(debounce: const Duration(milliseconds: 500));
      await watcher.start();
      // Warm up so the watcher is known to be live, then let it settle.
      final warm = File(p.join(lib, 'warm.dart'));
      await saveUntilReload(
        (i) async => warm.writeAsStringSync('w$i'),
        window: const Duration(seconds: 2),
      );
      await Future<void>.delayed(_fast * 5);
      final base = reloads;
      for (var d = 0; d < 10; d++) {
        Directory(p.join(lib, 'gen$d')).createSync();
      }
      for (var i = 0; i < 200; i++) {
        File(p.join(lib, 'gen${i % 10}', 'f$i.dart')).writeAsStringSync('c$i');
      }
      await eventually(() => reloads > base, reason: 'reload after burst');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final count = reloads - base;
      expect(count, inInclusiveRange(1, 2));
    });

    test('a new subdirectory under lib is picked up', () async {
      await startWatcher();
      final sub = Directory(p.join(lib, 'features', 'new'))
        ..createSync(recursive: true);
      final file = File(p.join(sub.path, 'x.dart'));
      await saveUntilReload((i) async => file.writeAsStringSync('n$i'));
      expect(notices, contains('Hot reload on save: lib/features/new/x.dart'));
    });

    test('glob directory outside lib is watched', () async {
      final assets = Directory(p.join(root, 'assets'))..createSync();
      watcher = make(globs: ['assets/**.json']);
      await watcher.start();
      final file = File(p.join(assets.path, 'd.json'));
      await saveUntilReload((i) async => file.writeAsStringSync('{"i":$i}'));
      expect(notices, contains('Hot reload on save: assets/d.json'));
    });
  });
}
