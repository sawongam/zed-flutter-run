import 'dart:async';
import 'dart:io';

import 'package:flutter_run/src/common/logger.dart';
import 'package:test/test.dart';

class _LineSink implements IOSink {
  final StringBuffer buffer = StringBuffer();
  @override
  void writeln([Object? object = '']) => buffer.writeln(object);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  final fixed = DateTime(2026, 11, 3, 9, 8, 7, 6);

  test('level filtering on stderr', () {
    final sink = _LineSink();
    Logger(level: LogLevel.warn, stderrSink: sink, clock: () => fixed)
      ..error('e')
      ..warn('w')
      ..info('i')
      ..debug('d');
    expect(
      sink.buffer.toString(),
      '09:08:07.006 ERROR e\n09:08:07.006 WARN w\n',
    );
  });

  test('levelFromName', () {
    expect(Logger.levelFromName('DEBUG'), LogLevel.debug);
    expect(Logger.levelFromName('warning'), LogLevel.warn);
    expect(Logger.levelFromName('nope'), LogLevel.info);
    expect(
      Logger.levelFromName(null, fallback: LogLevel.error),
      LogLevel.error,
    );
  });

  test('log file gets debug and dap traffic; nothing goes to stdout', () async {
    final dir = Directory.systemTemp.createTempSync('rd_log');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = '${dir.path}/log.log';
    final sink = _LineSink();
    final out = <String>[];
    await runZoned(
      () async {
        final logger = Logger(
          stderrSink: sink,
          logFilePath: file,
          clock: () => fixed,
        );
        logger
          ..info('hello')
          ..debug('details')
          ..trace('too much')
          ..dap('C>A', {'seq': 1});
        await logger.close();
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => out.add(line),
      ),
    );
    final text = File(file).readAsStringSync();
    expect(text, contains('INFO hello'));
    expect(text, contains('DEBUG details'));
    expect(text, isNot(contains('too much')));
    expect(text, contains('TRACE C>A {"seq":1}'));
    expect(sink.buffer.toString(), contains('hello'));
    expect(sink.buffer.toString(), isNot(contains('details')));
    expect(sink.buffer.toString(), isNot(contains('C>A')));
    expect(out, isEmpty);
    if (!Platform.isWindows) {
      expect(FileStat.statSync(file).mode & 0x1FF, 384);
    }
  });

  test('refuses bad log paths with one warning and keeps working', () async {
    final dir = Directory.systemTemp.createTempSync('rd_log2');
    addTearDown(() => dir.deleteSync(recursive: true));
    for (final path in ['${dir.path}/x.txt', '${dir.path}/missing/x.log']) {
      final sink = _LineSink();
      final logger = Logger(stderrSink: sink, logFilePath: path);
      logger.info('still works');
      await logger.close();
      expect(sink.buffer.toString(), contains('Warning'));
      expect(sink.buffer.toString(), contains('still works'));
      expect(File(path).existsSync(), isFalse);
      expect(Directory('${dir.path}/missing').existsSync(), isFalse);
    }
    if (!Platform.isWindows) {
      File('${dir.path}/t.log').writeAsStringSync('');
      Link('${dir.path}/l.log').createSync('${dir.path}/t.log');
      final sink = _LineSink();
      Logger(stderrSink: sink, logFilePath: '${dir.path}/l.log').info('x');
      expect(sink.buffer.toString(), contains('not a regular file'));
    }
  });

  test('control characters are escaped; unprintable dap is safe', () async {
    final dir = Directory.systemTemp.createTempSync('rd_log3');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = '${dir.path}/e.log';
    final sink = _LineSink();
    final logger = Logger(stderrSink: sink, logFilePath: file);
    logger.info('a\nb\r\x01c');
    Object nested = 1;
    for (var i = 0; i < 200000; i++) {
      nested = [nested];
    }
    logger.dap('C>A', nested);
    await logger.close();
    final text = File(file).readAsStringSync();
    expect(text.trimRight().split('\n').length, 2);
    expect(text, contains(r'a\nb\r\x01c'));
    expect(text, contains('<unprintable message>'));
    expect(sink.buffer.toString().trimRight().split('\n').length, 1);
  });

  test('capturing and silent loggers', () {
    final lines = <String>[];
    Logger.capturing(lines, level: LogLevel.debug)
      ..debug('a')
      ..trace('b')
      ..dap('SYN', 'x');
    expect(lines.length, 1);
    expect(lines.single, endsWith('DEBUG a'));
    final all = <String>[];
    Logger.capturing(all)
      ..trace('b')
      ..dap('INJ', {'k': 1});
    expect(all.length, 2);
    Logger.silent()
      ..error('x')
      ..info('y')
      ..dap('C>A', 1);
  });
}
