import 'package:flutter_run/src/cli/path_notice.dart';
import 'package:flutter_run/src/common/host_environment.dart';
import 'package:test/test.dart';

HostEnvironment _host(HostOs os) =>
    HostEnvironment(os: os, environment: const {}, currentDirectory: '/');

void main() {
  group('pathFixHint', () {
    test('Linux and macOS suggest an export line in the shell profile', () {
      for (final os in [HostOs.linux, HostOs.macos]) {
        final hint = pathFixHint(os, '/opt/flutter_run');
        expect(hint, contains('export PATH="/opt/flutter_run:\$PATH"'));
        expect(hint, contains('shell profile'));
      }
    });

    test('Windows describes the Environment Variables dialog', () {
      final hint = pathFixHint(HostOs.windows, r'C:\tools\flutter_run');
      expect(hint, contains(r'C:\tools\flutter_run'));
      expect(hint, contains('Environment Variables'));
      expect(hint, isNot(contains('export')));
    });
  });

  group('pathNoticeText', () {
    test('names the executable, its folder and the README for a binary', () {
      final text = pathNoticeText(
        _host(HostOs.linux),
        '/home/me/.local/share/zed/flutter_run',
        true,
      );
      expect(text, contains('is not on your PATH'));
      expect(text, contains('"Flutter: Hot Reload"'));
      expect(text, contains('using /home/me/.local/share/zed/flutter_run.'));
      expect(text, contains('Add /home/me/.local/share/zed to your PATH'));
      expect(text, contains('export PATH='));
      expect(text, contains('README section "Install"'));
      expect(text, contains('Rerun Session'));
      expect(text, isNot(contains('\n')));
    });

    test('uses the Windows how-to on Windows', () {
      final text = pathNoticeText(
        _host(HostOs.windows),
        r'C:\Users\me\flutter_run.exe',
        true,
      );
      expect(text, contains(r'Add C:\Users\me to your PATH'));
      expect(text, contains('Advanced system settings'));
      expect(text, isNot(contains('export')));
    });

    test('says the command is not installed when running from source', () {
      final text = pathNoticeText(_host(HostOs.linux), '/usr/bin/dart', false);
      expect(text, contains('is not installed'));
      expect(text, contains('runs from source (/usr/bin/dart)'));
      expect(text, isNot(contains('export PATH')));
      expect(text, contains('README section "Install"'));
    });
  });
}
