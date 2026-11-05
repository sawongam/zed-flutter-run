import 'dart:io';

import 'package:flutter_run/src/common/errors.dart';
import 'package:flutter_run/src/common/files.dart';
import 'package:flutter_run/src/common/host_environment.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('rd_files'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('atomicWriteString creates parents and replaces content', () async {
    final path = '${tmp.path}/a/b/file.json';
    await atomicWriteString(path, 'one');
    expect(File(path).readAsStringSync(), 'one');
    await atomicWriteString(path, 'two ü');
    expect(File(path).readAsStringSync(), 'two ü');
    expect(Directory('${tmp.path}/a/b').listSync().length, 1);
  });

  test('readers never see a partial file during rewrites', () async {
    final path = '${tmp.path}/state.json';
    final big = 'x' * 200000;
    await atomicWriteString(path, big);
    var done = false;
    final writer = () async {
      for (var i = 0; i < 40; i++) {
        await atomicWriteString(path, i.isEven ? big : 'y' * 200000);
      }
      done = true;
    }();
    while (!done) {
      final String text;
      try {
        text = File(path).readAsStringSync();
      } on PathAccessException {
        // Windows: a read can collide with the rename (sharing violation).
        await Future<void>.delayed(Duration.zero);
        continue;
      }
      expect(text.length, 200000);
      expect(text.codeUnits.toSet().length, 1);
      await Future<void>.delayed(Duration.zero);
    }
    await writer;
  });

  test('failure leaves no temp file', () async {
    final dir = Directory('${tmp.path}/target')..createSync();
    await expectLater(
      atomicWriteString(dir.path, 'x'),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      tmp.listSync().map((e) => e.path).where((p) => p.contains('.tmp-')),
      isEmpty,
    );
  });

  test('ensureOwnerOnlyDirectory sets mode 0700 on POSIX', () async {
    final env = HostEnvironment.system();
    final path = '${tmp.path}/x/sessions';
    await ensureOwnerOnlyDirectory(path, env);
    expect(Directory(path).existsSync(), isTrue);
    if (!Platform.isWindows) {
      expect(FileStat.statSync(path).mode & 0x1FF, 448);
    }
    await ensureOwnerOnlyDirectory(path, env); // idempotent
  });

  test(
    'a symlinked target stays a symlink and the real file is updated',
    () async {
      if (Platform.isWindows) return;
      final real = '${tmp.path}/real.json';
      File(real).writeAsStringSync('old');
      final link = '${tmp.path}/link.json';
      Link(link).createSync(real);
      await atomicWriteString(link, 'new');
      expect(FileSystemEntity.isLinkSync(link), isTrue);
      expect(File(real).readAsStringSync(), 'new');
      // dangling link: creates the target
      final dangling = '${tmp.path}/d.json';
      Link(dangling).createSync('${tmp.path}/made.json');
      await atomicWriteString(dangling, 'z');
      expect(FileSystemEntity.isLinkSync(dangling), isTrue);
      expect(File('${tmp.path}/made.json').readAsStringSync(), 'z');
    },
  );

  test('ensureOwnerOnlyDirectory refuses a symlinked directory', () async {
    if (Platform.isWindows) return;
    final victim = Directory('${tmp.path}/victim')..createSync();
    Process.runSync('chmod', ['755', victim.path]);
    Link('${tmp.path}/sessions').createSync(victim.path);
    await expectLater(
      ensureOwnerOnlyDirectory(
        '${tmp.path}/sessions',
        HostEnvironment.system(),
      ),
      throwsA(
        isA<FlutterRunException>().having((e) => e.hint, 'hint', isNotNull),
      ),
    );
    expect(FileStat.statSync(victim.path).mode & 0x1FF, 493);
  });
}
