import 'package:flutter_run/src/common/host_environment.dart';
import 'package:flutter_run/src/sdk/process_spec.dart';
import 'package:test/test.dart';

HostEnvironment fake(HostOs os) =>
    HostEnvironment(os: os, environment: const {}, currentDirectory: '/');

void main() {
  final win = fake(HostOs.windows);
  const bat = r'C:\Program Files\flutter\bin\flutter.bat';

  test('isBatchFile', () {
    expect(isBatchFile(r'C:\a\flutter.bat'), isTrue);
    expect(isBatchFile(r'C:\a\FLUTTER.CMD'), isTrue);
    expect(isBatchFile(r'C:\a\dart.exe'), isFalse);
    expect(isBatchFile('/usr/bin/flutter'), isFalse);
  });

  test('accepts the normal vocabulary for .bat targets', () {
    for (final args in [
      ['debug_adapter'],
      ['devices', '--machine'],
      ['emulators', '--launch', 'Pixel_7_API_34'],
      ['--version'],
      ['-d', 'emulator-5554'],
      ['-d', '00008110-001A2B3C4D5E:6F'],
      ['-d', 'user@host.local'],
      ['--device-id=chrome', r'C:\My Project\lib\main.dart'],
    ]) {
      final spec = buildProcessSpec(bat, args, win);
      expect(spec.executable, bat);
      expect(spec.arguments, args);
      expect(spec.workingDirectory, isNull);
    }
  });

  test('rejects dangerous characters for .bat/.cmd on Windows', () {
    for (final bad in [
      'a&b',
      'a|b',
      '%PATH%',
      'a^b',
      'a"b',
      'a<b',
      'a>b',
      'hi!',
      'a\nb',
      'a\rb',
      r'dir\',
      '&calc',
      'x\u0000y',
      'a(b',
      'a)b',
      'a,b',
      'a;b',
      'a\tb',
    ]) {
      expect(
        () => buildProcessSpec(bat, ['-d', bad], win),
        throwsArgumentError,
        reason: bad,
      );
      expect(
        () => buildProcessSpec(r'C:\x\tool.cmd', [bad], win),
        throwsArgumentError,
      );
      expect(() => validateBatchArgument(bad), throwsArgumentError);
    }
  });

  test('rejects cmd metacharacters in a .bat executable path', () {
    for (final bad in [
      r'C:\%TEMP%\flutter.bat',
      r'C:\a!b\flutter.bat',
      r'C:\a^b\flutter.bat',
    ]) {
      expect(() => buildProcessSpec(bad, ['x'], win), throwsArgumentError);
    }
  });

  test('exe targets and other platforms are not restricted', () {
    expect(buildProcessSpec(r'C:\dart\dart.exe', ['a&b'], win).arguments, [
      'a&b',
    ]);
    expect(
      buildProcessSpec('/usr/bin/flutter', [
        'a&b',
      ], fake(HostOs.linux)).arguments,
      ['a&b'],
    );
    expect(
      buildProcessSpec('/x/flutter.bat', ['a&b'], fake(HostOs.macos)).arguments,
      ['a&b'],
    );
  });

  test('returned argument list is unmodifiable and a copy', () {
    final args = ['a'];
    final spec = buildProcessSpec('/x/y', args, fake(HostOs.linux));
    args.add('b');
    expect(spec.arguments, ['a']);
    expect(() => spec.arguments.add('c'), throwsUnsupportedError);
  });

  test('safeIdPattern', () {
    for (final ok in [
      'emulator-5554',
      'chrome',
      'Pixel_7.API:34',
      'a@b',
      '00008110-001A',
    ]) {
      expect(safeIdPattern.hasMatch(ok), isTrue, reason: ok);
    }
    for (final bad in ['', 'a b', 'a&b', 'a"b', 'a%b', 'a\nb', 'a/b', 'a;b']) {
      expect(safeIdPattern.hasMatch(bad), isFalse, reason: bad);
    }
  });
}
