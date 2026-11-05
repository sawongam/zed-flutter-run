import 'package:flutter_run/src/devtools/pages.dart';
import 'package:flutter_run/src/devtools/url_builder.dart';
import 'package:test/test.dart';

void main() {
  const ws = 'ws://127.0.0.1:35233/abc=/ws';
  String enc(String s) => Uri.encodeQueryComponent(s);

  group('normalizeWsUri', () {
    for (final input in [
      'ws://127.0.0.1:35233/abc=/ws',
      'http://127.0.0.1:35233/abc=/',
      'http://127.0.0.1:35233/abc=',
      'ws://127.0.0.1:35233/abc=/ws/',
      '  http://127.0.0.1:35233/abc=/  ',
    ]) {
      test('accepts "$input"', () => expect(normalizeWsUri(input), ws));
    }

    test('repeated trailing /ws is collapsed', () {
      expect(normalizeWsUri('ws://127.0.0.1:35233/abc=/ws/ws'), ws);
      expect(normalizeWsUri('http://127.0.0.1:35233/abc=/ws/ws/'), ws);
    });

    test('token-less address', () {
      expect(normalizeWsUri('ws://127.0.0.1:9/ws'), 'ws://127.0.0.1:9/ws');
      expect(normalizeWsUri('http://localhost:9'), 'ws://localhost:9/ws');
    });

    test('token with = - _ and IPv6 loopback', () {
      expect(
        normalizeWsUri('http://[::1]:80/a-b_c=/'),
        'ws://[::1]:80/a-b_c=/ws',
      );
    });

    for (final bad in [
      '',
      'not a uri',
      'ftp://127.0.0.1:1/x=/',
      'file:///etc/passwd',
      'ws://127.0.0.1/abc=/ws',
      'ws:///abc=/ws',
      '/abc=/ws',
    ]) {
      test('rejects "$bad"', () {
        expect(() => normalizeWsUri(bad), throwsFormatException);
      });
    }
  });

  group('buildDdsDevToolsUrl', () {
    test('golden URL for every page', () {
      for (final page in DevToolsPage.values) {
        final url = buildDdsDevToolsUrl(ws, page);
        expect(
          url.toString(),
          'http://127.0.0.1:35233/abc=/devtools/${page.route}'
          '?uri=${enc(ws)}',
        );
      }
    });

    test('percent-encodes the ws URI', () {
      final s = buildDdsDevToolsUrl(ws, DevToolsPage.inspector).toString();
      expect(
        s,
        'http://127.0.0.1:35233/abc=/devtools/inspector'
        '?uri=ws%3A%2F%2F127.0.0.1%3A35233%2Fabc%3D%2Fws',
      );
    });

    test('all three input forms give the same URL', () {
      final urls = {
        for (final i in [
          'ws://127.0.0.1:35233/abc=/ws',
          'http://127.0.0.1:35233/abc=/',
          'http://127.0.0.1:35233/abc=',
        ])
          buildDdsDevToolsUrl(i, DevToolsPage.memory).toString(),
      };
      expect(urls, hasLength(1));
    });

    test('token with = - _ round-trips', () {
      final url = buildDdsDevToolsUrl(
        'ws://127.0.0.1:1/a-b_c==/ws',
        DevToolsPage.network,
      );
      expect(url.path, '/a-b_c==/devtools/network');
      expect(url.queryParameters['uri'], 'ws://127.0.0.1:1/a-b_c==/ws');
    });

    test('IPv6 loopback', () {
      final url = buildDdsDevToolsUrl(
        'ws://[::1]:4000/tok=/ws',
        DevToolsPage.logging,
      );
      expect(url.toString(), startsWith('http://[::1]:4000/tok=/devtools/'));
      expect(url.queryParameters['uri'], 'ws://[::1]:4000/tok=/ws');
      expect(isSafeBrowserUrl(url), isTrue);
    });

    test('rejects invalid input', () {
      expect(
        () => buildDdsDevToolsUrl('garbage', DevToolsPage.inspector),
        throwsFormatException,
      );
    });
  });

  group('isSafeBrowserUrl', () {
    for (final ok in [
      'http://127.0.0.1:1/x',
      'http://localhost:2/x',
      'http://[::1]:3/x',
      'https://localhost/x',
      'HTTP://LOCALHOST:2/x',
    ]) {
      test('accepts $ok', () => expect(isSafeBrowserUrl(Uri.parse(ok)), true));
    }
    for (final bad in [
      'file:///etc/passwd',
      'javascript:alert(1)',
      'http://example.com/',
      'http://127.0.0.1.evil.com/',
      'http://localhost@evil.com/',
      'http://192.168.1.2:1/',
      'ftp://127.0.0.1/',
      'ws://127.0.0.1:1/',
      '/relative',
    ]) {
      test(
        'rejects $bad',
        () => expect(isSafeBrowserUrl(Uri.parse(bad)), false),
      );
    }
  });

  group('DevToolsPage.parse', () {
    test('route names and aliases', () {
      for (final p in DevToolsPage.values) {
        expect(DevToolsPage.parse(p.route), p);
      }
      expect(DevToolsPage.parse('cpu_profiler'), DevToolsPage.cpuProfiler);
      expect(DevToolsPage.parse('cpuprofiler'), DevToolsPage.cpuProfiler);
      expect(DevToolsPage.parse('CPU-Profiler'), DevToolsPage.cpuProfiler);
    });
    test('unknown', () {
      expect(DevToolsPage.parse('foo'), isNull);
      expect(DevToolsPage.parse(''), isNull);
    });
  });
}
