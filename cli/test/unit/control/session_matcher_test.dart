import 'package:flutter_run/src/common/host_environment.dart';
import 'package:flutter_run/src/control/session_matcher.dart';
import 'package:test/test.dart';

HostEnvironment env(HostOs os) =>
    HostEnvironment(os: os, environment: const {}, currentDirectory: '/');

List<String> match(List<String> roots, String dir, HostEnvironment e) =>
    matchSessions<String>(roots, (r) => r, dir, e);

void main() {
  final linux = env(HostOs.linux);

  test('equal, child, parent match; sibling and prefix-sibling do not', () {
    const roots = ['/a/b', '/a/bc', '/a/b/c', '/x'];
    expect(match(roots, '/a/b', linux), ['/a/b', '/a/b/c']);
    // D inside the project.
    expect(match(['/a/b'], '/a/b/lib/src', linux), ['/a/b']);
    // D is a parent (monorepo worktree root).
    expect(match(roots, '/a', linux), ['/a/b', '/a/bc', '/a/b/c']);
    expect(match(['/a/b'], '/a/c', linux), isEmpty);
    expect(match(['/a/bc'], '/a/b', linux), isEmpty);
    expect(match(['/a/b'], '/a/bc', linux), isEmpty);
  });

  test('trailing separators and dot segments are normalised', () {
    expect(match(['/a/b/'], '/a/./b', linux), ['/a/b/']);
  });

  test('Linux paths are case-sensitive', () {
    expect(match(['/a/App'], '/a/app', linux), isEmpty);
  });

  test('Windows matches case-insensitively in both directions', () {
    final win = env(HostOs.windows);
    expect(
      match([r'C:\Users\Me\App'], r'c:\users\me\app\lib', win),
      hasLength(1),
    );
    expect(match([r'c:\users\me\app\sub'], r'C:\Users\Me', win), hasLength(1));
    expect(match([r'C:\Users\Me\App'], r'C:\Users\Me\AppX', win), isEmpty);
    expect(match([r'C:\a\b'], r'D:\a\b', win), isEmpty);
  });

  test('macOS matches case-insensitively in both directions', () {
    final mac = env(HostOs.macos);
    expect(match(['/Users/Me/App'], '/users/me/app/lib', mac), hasLength(1));
    expect(match(['/users/me/app/sub'], '/Users/Me', mac), hasLength(1));
    expect(match(['/Users/Me/App'], '/Users/Me/AppX', mac), isEmpty);
  });
}
