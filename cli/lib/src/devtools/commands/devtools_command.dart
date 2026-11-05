import 'package:args/command_runner.dart';

import '../../common/console.dart';
import '../../common/errors.dart';
import '../../common/global_options.dart';
import '../../common/host_environment.dart';
import '../browser_opener.dart';
import '../pages.dart';
import '../url_builder.dart';

/// The running app a DevTools page is opened for.
class VmServiceTarget {
  const VmServiceTarget({
    required this.vmServiceUri,
    this.deviceId,
    required this.sessionPid,
    this.kind,
  });

  final String vmServiceUri;
  final String? deviceId;
  final int sessionPid;

  /// Session kind (`flutter` or `dart`); null when unknown.
  final String? kind;
}

/// Finds the session for [directory] (most recent `startedAt` with a
/// `vmServiceUri`). Throws [NoSessionException] (exit 3) or
/// [SessionRequestException] (exit 4, app still starting).
typedef VmServiceTargetResolver =
    Future<VmServiceTarget> Function({required String directory});

class DevToolsCommand extends Command<int> {
  DevToolsCommand({
    required VmServiceTargetResolver resolveTarget,
    required BrowserOpener opener,
    required HostEnvironment env,
    required Console console,
  }) : _resolveTarget = resolveTarget,
       _opener = opener,
       _env = env,
       _console = console {
    GlobalOptions.addTo(argParser);
    argParser.addFlag(
      'print',
      negatable: false,
      help: 'Only print the DevTools URL; do not open a browser.',
    );
  }

  final VmServiceTargetResolver _resolveTarget;
  final BrowserOpener _opener;
  final HostEnvironment _env;
  final Console _console;

  @override
  String get name => 'devtools';

  @override
  String get description =>
      'Open DevTools for the running Flutter app '
      '(pages: ${DevToolsPage.names}).';

  @override
  String get invocation =>
      '${runner?.executableName ?? 'flutter_run'} '
      'devtools [page] [--print]';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length > 1) {
      throw UsageError(
        'Give at most one DevTools page.',
        hint: 'Available pages: ${DevToolsPage.names}.',
      );
    }
    var page = DevToolsPage.inspector;
    if (rest.isNotEmpty) {
      final parsed = DevToolsPage.parse(rest.single);
      if (parsed == null) {
        throw UsageError(
          'Unknown DevTools page "${rest.single}".',
          hint: 'Available pages: ${DevToolsPage.names}.',
        );
      }
      page = parsed;
    }
    final printOnly = argResults!['print'] as bool;
    final directory = GlobalOptions.of(this).project ?? _env.currentDirectory;

    final target = await _resolveTarget(directory: directory);
    if (target.kind == 'dart') {
      throw SessionRequestException(
        'DevTools cannot be opened for a Dart console session from here.',
        hint:
            'Run "dart devtools" and paste this VM service address when it '
            'asks for one: ${target.vmServiceUri}',
      );
    }
    final Uri url;
    try {
      url = buildDdsDevToolsUrl(target.vmServiceUri, page);
    } on FormatException catch (e) {
      throw SessionRequestException(
        'The app reported an address that DevTools cannot use: ${e.message}',
        hint: 'Restart the debug session and try again.',
      );
    }

    if (printOnly) {
      _console.out(url.toString());
      return ExitCodes.ok;
    }
    _console.out('Opening DevTools: $url');
    try {
      await _opener.open(url);
    } on FlutterRunException catch (e) {
      _console.err('Error: ${e.message}');
      _console.err(
        e is BrowserRefusedException
            ? 'Run "flutter_run devtools --print" to show the address.'
            : 'The DevTools address is printed above; open it in a browser '
                  'yourself. If the page does not load, DevTools needs the '
                  'Dart Development Service, which is on by default.',
      );
      return ExitCodes.externalToolFailed;
    }
    return ExitCodes.ok;
  }
}
