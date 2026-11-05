import 'dart:convert';

import 'package:args/command_runner.dart';

import '../common/console.dart';
import '../common/errors.dart';
import '../common/global_options.dart';
import '../common/host_environment.dart';
import '../common/paths.dart';
import 'session_matcher.dart';
import 'session_store.dart';

/// `flutter_run status [--json]`: running sessions from the session files.
class StatusCommand extends Command<int> {
  StatusCommand({
    required SessionStore store,
    required HostEnvironment env,
    required Console console,
  }) : _store = store,
       _env = env,
       _console = console {
    GlobalOptions.addTo(argParser);
    argParser.addFlag(
      'json',
      negatable: false,
      help: 'Print the sessions as JSON.',
    );
  }

  final SessionStore _store;
  final HostEnvironment _env;
  final Console _console;

  @override
  String get name => 'status';

  @override
  String get description => 'List the running debug sessions.';

  @override
  Future<int> run() async {
    final options = GlobalOptions.of(this);
    final directory = canonicalDirectory(
      options.project ?? _env.currentDirectory,
      _env,
    );
    final records = await _store.list();
    final matching = matchSessions<SessionRecord>(
      records,
      (r) => r.info.projectRoot,
      directory,
      _env,
    ).toSet();

    if (argResults?['json'] == true) {
      _console.out(
        const JsonEncoder.withIndent('  ').convert({
          'directory': directory,
          'sessions': [
            for (final r in records)
              {
                'pid': r.info.pid,
                'kind': r.info.kind,
                'request': r.info.request,
                'projectRoot': r.info.projectRoot,
                'cwd': r.info.cwd,
                'startedAt': r.info.startedAt.toUtc().toIso8601String(),
                'deviceId': r.info.deviceId,
                'mode': r.info.mode,
                'vmServiceUri': r.info.vmServiceUri,
                'appStarted': r.info.appStarted,
                'unresponsive': r.unresponsive,
                'matches': matching.contains(r),
              },
          ],
        }),
      );
      return ExitCodes.ok;
    }

    if (records.isEmpty) {
      _console.out(
        'No running debug sessions. Start one from the debugger (F4 opens '
        'the debug picker in Zed).',
      );
      return ExitCodes.ok;
    }
    for (final r in records) {
      final info = r.info;
      final state = r.unresponsive
          ? 'not answering'
          : info.appStarted
          ? 'running'
          : 'starting';
      final project = _env.pathContext.basename(info.projectRoot);
      final marker = matching.contains(r) ? '*' : ' ';
      _console.out(
        '$marker pid ${info.pid}  ${info.kind}  ${info.deviceId ?? '-'}  '
        '$project  $state  ${info.projectRoot}',
      );
    }
    if (matching.isNotEmpty) {
      _console.out('* matches $directory');
    }
    return ExitCodes.ok;
  }
}
