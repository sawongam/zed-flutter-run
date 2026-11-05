import 'package:flutter_run/src/common/host_environment.dart';
import 'package:test/test.dart';

void main() {
  HostEnvironment make(
    HostOs os,
    Map<String, String> env, [
    String cwd = '/w',
  ]) => HostEnvironment(os: os, environment: env, currentDirectory: cwd);

  test('env lookup is case-insensitive only on Windows', () {
    final win = make(HostOs.windows, {'Path': r'C:\x'}, r'C:\w');
    expect(win.env('PATH'), r'C:\x');
    expect(win.env('path'), r'C:\x');
    expect(win.env('NOPE'), isNull);
    final linux = make(HostOs.linux, {'Path': '/x'});
    expect(linux.env('PATH'), isNull);
    expect(linux.env('Path'), '/x');
  });

  test('home and flags per OS', () {
    expect(make(HostOs.linux, {'HOME': '/h'}).home, '/h');
    expect(make(HostOs.macos, {'HOME': '/h'}).pathsCaseInsensitive, isTrue);
    expect(make(HostOs.linux, {}).pathsCaseInsensitive, isFalse);
    final win = make(HostOs.windows, {'userprofile': r'C:\Users\Me'}, r'C:\w');
    expect(win.home, r'C:\Users\Me');
    expect(win.isWindows, isTrue);
    expect(make(HostOs.linux, {}).home, isNull);
    expect(
      HostEnvironment(
        os: HostOs.linux,
        environment: {},
        currentDirectory: '/',
        homeOverride: '/o',
      ).home,
      '/o',
    );
  });

  test('pathContext style and copyWith', () {
    final win = make(HostOs.windows, {}, r'C:\w');
    expect(win.pathContext.join('a', 'b'), r'a\b');
    final linux = win.copyWith(os: HostOs.linux, currentDirectory: '/z');
    expect(linux.pathContext.join('a', 'b'), 'a/b');
    expect(linux.currentDirectory, '/z');
    expect(HostEnvironment.system().currentDirectory, isNotEmpty);
  });
}
