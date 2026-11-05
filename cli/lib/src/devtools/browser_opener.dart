import 'dart:async';
import 'dart:io';

import '../common/errors.dart';
import '../common/host_environment.dart';
import '../common/logger.dart';
import 'url_builder.dart';

/// An executable plus arguments; run without a shell.
class BrowserCommand {
  const BrowserCommand(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

/// The command that opens [url] in the default browser on [os]. The URL is a
/// single argument, so `&` and `=` need no quoting.
BrowserCommand browserCommandFor(HostOs os, String url) => switch (os) {
  HostOs.linux => BrowserCommand('xdg-open', [url]),
  HostOs.macos => BrowserCommand('open', [url]),
  HostOs.windows => BrowserCommand('rundll32', [
    'url.dll,FileProtocolHandler',
    url,
  ]),
};

abstract interface class BrowserOpener {
  /// Throws [ExternalToolException] when the browser cannot be launched.
  Future<void> open(Uri url);
}

/// Runs a process and returns its exit code (a fake in tests).
typedef BrowserProcessRunner =
    Future<int> Function(String executable, List<String> arguments);

/// Starts the launcher detached (no pipes are captured, so a browser that the
/// launcher leaves running in the background cannot block or time out the
/// command) and returns 0 once it has been spawned. Throws [ProcessException]
/// if it cannot be started. Never uses a shell.
Future<int> runBrowserProcess(String executable, List<String> arguments) async {
  await Process.start(
    executable,
    arguments,
    mode: ProcessStartMode.detached,
    runInShell: false,
  );
  return 0;
}

/// The URL was refused because it is not a local http address.
class BrowserRefusedException extends ExternalToolException {
  const BrowserRefusedException(super.message, {super.hint});
}

class SystemBrowserOpener implements BrowserOpener {
  SystemBrowserOpener(
    this._env, {
    Logger? logger,
    BrowserProcessRunner? runProcess,
  }) : _logger = logger ?? Logger.silent(),
       _run = runProcess ?? runBrowserProcess;

  final HostEnvironment _env;
  final Logger _logger;
  final BrowserProcessRunner _run;

  @override
  Future<void> open(Uri url) async {
    if (!isSafeBrowserUrl(url)) {
      throw BrowserRefusedException(
        'Refusing to open $url because it is not a local http address.',
      );
    }
    final command = browserCommandFor(_env.os, url.toString());
    _logger.debug(
      'Opening browser: ${command.executable} ${command.arguments.join(' ')}',
    );
    try {
      final code = await _run(command.executable, command.arguments);
      if (code != 0) {
        throw ExternalToolException(
          'The browser launcher ${command.executable} exited with code $code.',
          hint: 'Open the printed DevTools URL in a browser yourself.',
        );
      }
    } on ExternalToolException {
      rethrow;
    } on ProcessException catch (e) {
      throw ExternalToolException(
        'Could not start ${command.executable}: ${e.message}.',
        hint: 'Open the printed DevTools URL in a browser yourself.',
        cause: e,
      );
    } on TimeoutException catch (e) {
      throw ExternalToolException(
        'The browser launcher ${command.executable} did not finish in time.',
        hint: 'Open the printed DevTools URL in a browser yourself.',
        cause: e,
      );
    }
  }
}
