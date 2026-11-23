import 'dart:io';

import 'package:flutter_run/src/common/clock.dart';
import 'package:flutter_run/src/common/host_environment.dart';
import 'package:flutter_run/src/common/logger.dart';
import 'package:flutter_run/src/control/control_client.dart';
import 'package:flutter_run/src/sdk/sdk_steps.dart';
import 'package:test/test.dart';

HostEnvironment _env(HostOs os) => HostEnvironment(
  os: os,
  environment: const {},
  currentDirectory: Directory.current.path,
);

/// The Windows and POSIX branches that used to read `Platform.isWindows`
/// directly, now driven by a [HostEnvironment] so any host can run both.
void main() {
  group('LocalSdkFileSystem.isExecutableFile', () {
    late Directory dir;
    late String plain;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('flutter_run_exec_');
      plain = '${dir.path}/plain.txt';
      File(plain).writeAsStringSync('x');
      if (!Platform.isWindows) Process.runSync('chmod', ['644', plain]);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('Windows counts any file as executable', () {
      expect(
        LocalSdkFileSystem(_env(HostOs.windows)).isExecutableFile(plain),
        isTrue,
      );
    }, skip: Platform.isWindows ? 'mode bits do not exist' : false);

    test('POSIX needs an execute bit', () {
      final fs = LocalSdkFileSystem(_env(HostOs.linux));
      expect(fs.isExecutableFile(plain), isFalse);
      Process.runSync('chmod', ['755', plain]);
      expect(fs.isExecutableFile(plain), isTrue);
    }, skip: Platform.isWindows ? 'mode bits do not exist' : false);
  });

  test('the loopback connect timeout is longer on Windows', () {
    expect(
      defaultConnectTimeoutFor(_env(HostOs.windows)),
      const Duration(seconds: 6),
    );
    expect(
      defaultConnectTimeoutFor(_env(HostOs.linux)),
      const Duration(seconds: 2),
    );
    expect(
      defaultConnectTimeoutFor(_env(HostOs.macos)),
      const Duration(seconds: 2),
    );
  });

  group('Logger log file permissions', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('flutter_run_log_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('POSIX restricts the log file to the user', () async {
      final path = '${dir.path}/a.log';
      await Logger(env: _env(HostOs.linux), logFilePath: path).close();
      expect(FileStat.statSync(path).mode & 0x1ff, 0x180); // 0600
    }, skip: Platform.isWindows ? 'mode bits do not exist' : false);

    test('Windows skips chmod and still opens the file', () async {
      final path = '${dir.path}/b.log';
      final logger = Logger(env: _env(HostOs.windows), logFilePath: path)
        ..info('hello');
      await logger.close();
      expect(File(path).readAsStringSync(), contains('hello'));
      expect(FileStat.statSync(path).mode & 0x1ff, isNot(0x180));
    }, skip: Platform.isWindows ? 'mode bits do not exist' : false);
  });

  test('SystemClock reads the real time', () {
    final before = DateTime.now();
    final now = const SystemClock().now();
    expect(now.difference(before).inSeconds.abs(), lessThan(5));
    final t = const SystemClock().timer(Duration.zero, () {})..cancel();
    expect(t.isActive, isFalse);
    expect(const SystemClock().stopwatch().isRunning, isFalse);
  });
}
