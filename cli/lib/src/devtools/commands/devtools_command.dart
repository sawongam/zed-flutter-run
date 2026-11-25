import 'package:args/command_runner.dart';

import '../../common/console.dart';
import '../../common/errors.dart';
import '../../common/global_options.dart';
import '../../common/host_environment.dart';
import '../browser_opener.dart';
import '../pages.dart';
import '../url_builder.dart';
import '../vm_service_target_resolver.dart';

class DevToolsCommand extends Command<int> {
  DevToolsCommand({
    required this._resolveTarget,
    required this._opener,
    required this._env,
    required this._console,
  }) {
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
    final style = _console.style;
    _console.out('${style.green('Opening DevTools:')} ${style.cyan('$url')}');
    try {
      await _opener.open(url);
    } on FlutterRunException catch (e) {
      final hint = e is BrowserRefusedException
          ? 'Run "flutter_run devtools --print" to show the address.'
          : 'The DevTools address is printed above; open it in a browser '
                'yourself. If the page does not load, DevTools needs the '
                'Dart Development Service, which is on by default.';
      final errStyle = _console.errStyle;
      _console
        ..err('${errStyle.error('error:')} ${e.message}')
        ..err('${errStyle.yellow('hint:')} $hint');
      return ExitCodes.externalToolFailed;
    }
    return ExitCodes.ok;
  }
}
