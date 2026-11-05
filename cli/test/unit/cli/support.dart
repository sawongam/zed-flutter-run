import 'dart:io';

import 'package:flutter_run/src/cli/wiring.dart';
import 'package:flutter_run/src/common/console.dart';
import 'package:flutter_run/src/common/host_environment.dart';
import 'package:flutter_run/src/common/logger.dart';

/// A [Wiring] on a throw-away directory with an empty PATH, so nothing on
/// the real machine leaks into the test.
class TestWiring {
  TestWiring({Map<String, String> env = const {}})
    : dir = Directory(
        // Canonical path: commands resolve it, and Windows temp paths use
        // 8.3 short names that would otherwise not compare equal.
        Directory.systemTemp
            .createTempSync('flutter_run_cli_test_')
            .resolveSymbolicLinksSync(),
      ) {
    console = MemoryConsole();
    wiring = Wiring(
      env: HostEnvironment(
        os: HostEnvironment.system().os,
        environment: {
          'PATH': '',
          'HOME': dir.path,
          'FLUTTER_RUN_STATE_DIR': '${dir.path}/state',
          ...env,
        },
        currentDirectory: dir.path,
      ),
      console: console,
      logger: Logger.silent(),
    );
  }

  final Directory dir;
  late final MemoryConsole console;
  late final Wiring wiring;

  /// Best effort: on Windows a just-stopped process can still hold a file.
  void dispose() {
    for (var attempt = 1; ; attempt++) {
      try {
        dir.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        if (!dir.existsSync()) return;
        if (attempt >= 10) return;
        sleep(const Duration(milliseconds: 100));
      }
    }
  }
}
