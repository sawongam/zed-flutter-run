import 'dart:io';

import 'package:flutter_run/src/common/errors.dart';
import 'package:flutter_run/src/common/host_environment.dart';
import 'package:flutter_run/src/devtools/browser_opener.dart';
import 'package:flutter_run/src/devtools/devtools_opener.dart';
import 'package:flutter_run/src/devtools/pages.dart';
import 'package:test/test.dart';

HostEnvironment hostOf(HostOs os) =>
    HostEnvironment(os: os, environment: const {}, currentDirectory: '/');

void main() {
  const url = 'http://127.0.0.1:1/t=/devtools/inspector?uri=ws%3A%2F%2Fx&a=b';

  group('browserCommandFor', () {
    test('linux', () {
      final c = browserCommandFor(HostOs.linux, url);
      expect(c.executable, 'xdg-open');
      expect(c.arguments, [url]);
    });
    test('macos', () {
      final c = browserCommandFor(HostOs.macos, url);
      expect(c.executable, 'open');
      expect(c.arguments, [url]);
    });
    test('windows', () {
      final c = browserCommandFor(HostOs.windows, url);
      expect(c.executable, 'rundll32');
      expect(c.arguments, ['url.dll,FileProtocolHandler', url]);
    });
  });

  group('SystemBrowserOpener', () {
    for (final os in HostOs.values) {
      test('runs exact argv on $os', () async {
        final calls = <List<String>>[];
        final opener = SystemBrowserOpener(
          hostOf(os),
          runProcess: (e, a) async {
            calls.add([e, ...a]);
            return 0;
          },
        );
        await opener.open(Uri.parse(url));
        final c = browserCommandFor(os, url);
        expect(calls, [
          [c.executable, ...c.arguments],
        ]);
      });
    }

    test('refuses non-loopback URLs without running anything', () async {
      var ran = false;
      final opener = SystemBrowserOpener(
        hostOf(HostOs.linux),
        runProcess: (e, a) async {
          ran = true;
          return 0;
        },
      );
      for (final bad in [
        'http://example.com/',
        'file:///etc/passwd',
        'javascript:alert(1)',
      ]) {
        await expectLater(
          opener.open(Uri.parse(bad)),
          throwsA(isA<ExternalToolException>()),
        );
      }
      expect(ran, isFalse);
    });

    test('non-zero exit becomes ExternalToolException', () async {
      final opener = SystemBrowserOpener(
        hostOf(HostOs.linux),
        runProcess: (e, a) async => 3,
      );
      await expectLater(
        opener.open(Uri.parse(url)),
        throwsA(
          isA<ExternalToolException>().having((e) => e.exitCode, 'code', 10),
        ),
      );
    });

    test('missing executable becomes ExternalToolException', () async {
      final opener = SystemBrowserOpener(
        hostOf(HostOs.linux),
        runProcess: (e, a) async =>
            throw const ProcessException('xdg-open', [], 'not found'),
      );
      await expectLater(
        opener.open(Uri.parse(url)),
        throwsA(isA<ExternalToolException>()),
      );
    });
  });

  group('runBrowserProcess (real)', () {
    test('returns promptly when the launcher leaves a child running', () async {
      final dir = Directory.systemTemp.createTempSync('wp6_opener');
      addTearDown(() => dir.deleteSync(recursive: true));
      final script = File('${dir.path}/fake-open.sh')
        ..writeAsStringSync(
          '#!/bin/sh\nsleep 30 &\necho \$! > "${dir.path}/child.pid"\nexit 0\n',
        );
      addTearDown(() {
        final pidFile = File('${dir.path}/child.pid');
        if (pidFile.existsSync()) {
          Process.runSync('kill', [pidFile.readAsStringSync().trim()]);
        }
      });
      Process.runSync('chmod', ['+x', script.path]);
      final sw = Stopwatch()..start();
      final code = await runBrowserProcess(script.path, ['http://x']);
      expect(code, 0);
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    }, skip: Platform.isWindows ? 'needs /bin/sh' : false);

    test('missing launcher throws ProcessException', () {
      expect(
        runBrowserProcess('/nonexistent/launcher', ['x']),
        throwsA(isA<ProcessException>()),
      );
    });
  });

  group('openDevToolsOnce', () {
    test('returns the URL on success', () async {
      final opened = <Uri>[];
      final result = await openDevToolsOnce(
        'ws://127.0.0.1:5/t=/ws',
        DevToolsPage.performance,
        _FakeOpener(opened.add),
      );
      expect(opened, [result]);
      expect(result.path, '/t=/devtools/performance');
    });

    test('failure throws an exception that carries the URL', () async {
      await expectLater(
        openDevToolsOnce(
          'ws://127.0.0.1:5/t=/ws',
          DevToolsPage.inspector,
          _FakeOpener((_) => throw const ExternalToolException('nope')),
        ),
        throwsA(
          isA<DevToolsOpenException>()
              .having((e) => e.url.port, 'port', 5)
              .having((e) => e.message, 'message', contains('127.0.0.1:5')),
        ),
      );
    });

    test('Dart session returns the URL without opening', () async {
      final opened = <Uri>[];
      final url = await openDevToolsOnce(
        'ws://127.0.0.1:5/t=/ws',
        DevToolsPage.inspector,
        _FakeOpener(opened.add),
        isDartSession: true,
      );
      expect(opened, isEmpty);
      expect(url.port, 5);
    });

    test('bad address is a session error', () async {
      await expectLater(
        openDevToolsOnce('junk', DevToolsPage.inspector, _FakeOpener((_) {})),
        throwsA(isA<SessionRequestException>()),
      );
    });
  });
}

class _FakeOpener implements BrowserOpener {
  _FakeOpener(this._onOpen);
  final void Function(Uri) _onOpen;
  @override
  Future<void> open(Uri url) async => _onOpen(url);
}
