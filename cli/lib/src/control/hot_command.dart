import 'dart:async';

import 'package:args/command_runner.dart';

import '../common/console.dart';
import '../common/errors.dart';
import '../common/global_options.dart';
import '../common/host_environment.dart';
import '../common/json_types.dart';
import '../common/paths.dart';
import 'control_client.dart';
import 'control_protocol.dart';
import 'session_matcher.dart';
import 'session_store.dart';

/// Shared behaviour of `reload` and `restart`: act on every matching,
/// started Flutter session at once and report one line per session.
abstract class HotActionCommand extends Command<int> {
  HotActionCommand({
    required SessionStore store,
    required ControlClient client,
    required HostEnvironment env,
    required Console console,
    required Duration waitingNoticeAfter,
  }) : _store = store,
       _client = client,
       _env = env,
       _console = console,
       _waitingNoticeAfter = waitingNoticeAfter {
    GlobalOptions.addTo(argParser);
    argParser.addOption(
      'timeout',
      valueHelp: 'seconds',
      defaultsTo: '120',
      help: 'How long to wait for each app before giving up.',
    );
  }

  final SessionStore _store;
  final ControlClient _client;
  final HostEnvironment _env;
  final Console _console;
  final Duration _waitingNoticeAfter;

  /// Control command on the wire.
  String get controlCommand;

  /// Prefix of result lines, for example `Hot reload`.
  String get actionLabel;

  Json get controlArgs;

  @override
  Future<int> run() async {
    final timeout = _parseTimeout();
    final options = GlobalOptions.of(this);
    final directory = canonicalDirectory(
      options.project ?? _env.currentDirectory,
      _env,
    );

    final all = await _store.list();
    final matching = matchSessions<SessionRecord>(
      all,
      (r) => r.info.projectRoot,
      directory,
      _env,
    );
    if (matching.isEmpty) {
      throw NoSessionException(
        'No running Flutter app found for $directory.',
        hint:
            'Start one from the debugger first (F4 opens the debug picker in '
            'Zed). Sessions started with the "Dart" adapter cannot be '
            'reloaded by this tool; use a scenario that uses the "FlutterRun" '
            'adapter.',
      );
    }

    final below = matching.where(
      (r) =>
          !pathsEqual(r.info.projectRoot, directory, _env) &&
          isWithin(directory, r.info.projectRoot, _env),
    );
    if (below.isNotEmpty) {
      _console.err(
        'Note: $directory contains Flutter projects, so every running app '
        'below it is included.',
      );
    }

    final eligible = <SessionRecord>[];
    for (final record in matching) {
      final info = record.info;
      if (info.kind != 'flutter') {
        _console.err(
          'Skipped pid ${info.pid}: it is a Dart console session, not a '
          'Flutter app.',
        );
      } else if (record.unresponsive) {
        _console.err(
          'Skipped pid ${info.pid}: it did not answer. If Zed is hung, stop '
          'that debug session.',
        );
      } else if (!info.appStarted) {
        _console.err('pid ${info.pid}: the app is still starting.');
      } else {
        eligible.add(record);
      }
    }
    if (eligible.isEmpty) return ExitCodes.sessionError;

    final waiting = Timer(_waitingNoticeAfter, () {
      _console.err(
        'Waiting... the app may be paused at a breakpoint (Ctrl+C to stop '
        'waiting).',
      );
    });
    final List<_Outcome> outcomes;
    try {
      outcomes = await Future.wait(eligible.map((r) => _act(r, timeout)));
    } finally {
      waiting.cancel();
    }

    var failed = false;
    var timedOut = false;
    for (final outcome in outcomes) {
      _console.out(outcome.line);
      if (!outcome.ok) failed = true;
      if (outcome.timedOut) timedOut = true;
    }
    if (timedOut) return ExitCodes.timeout;
    if (failed) return ExitCodes.sessionError;
    return ExitCodes.ok;
  }

  Duration _parseTimeout() {
    final raw = argResults?['timeout'] as String? ?? '120';
    final seconds = int.tryParse(raw.trim());
    if (seconds == null || seconds <= 0) {
      throw const UsageError(
        'The --timeout value must be a whole number of seconds above zero.',
      );
    }
    return Duration(seconds: seconds);
  }

  Future<_Outcome> _act(SessionRecord record, Duration timeout) async {
    final info = record.info;
    final device = info.deviceId ?? 'unknown device';
    final project = _env.pathContext.basename(info.projectRoot);
    final prefix = '$actionLabel: $device $project';
    _Outcome failure(String message, {bool timedOut = false}) => _Outcome(
      '$prefix ${_mark('failed')}: $message',
      ok: false,
      timedOut: timedOut,
    );
    try {
      final response = await _client.send(
        info,
        controlCommand,
        args: controlArgs,
        timeout: timeout,
      );
      if (response.ok) {
        final ms = response.result?['durationMs'];
        final seconds = ms is num ? (ms / 1000).toStringAsFixed(1) : '?';
        final coalesced = response.result?['coalesced'] == true;
        return _Outcome(
          '$prefix ${_mark('ok')} in $seconds s'
          '${coalesced ? ' (joined a reload that was already running)' : ''}',
          ok: true,
        );
      }
      final message = response.errorMessage ?? 'The session reported an error.';
      return switch (response.errorCode) {
        ControlErrorCode.timeout => failure(message, timedOut: true),
        ControlErrorCode.appNotStarted => failure('the app is still starting.'),
        ControlErrorCode.busy => failure(
          'another reload or restart is still running.',
        ),
        ControlErrorCode.sessionEnded => failure(
          'the debug session has ended.',
        ),
        _ => failure(message),
      };
    } on ControlClientException catch (e) {
      return switch (e.failure) {
        ControlClientFailure.timeout => failure(
          'no answer within ${timeout.inSeconds} s.',
          timedOut: true,
        ),
        ControlClientFailure.refused || ControlClientFailure.unreachable =>
          failure('the session is no longer running.'),
        ControlClientFailure.protocol ||
        ControlClientFailure.notProtocol => failure(e.message),
      };
    }
  }

  String _mark(String word) {
    if (!_console.useColor) return word;
    final code = word == 'ok' ? '32' : '31';
    return '\x1B[${code}m$word\x1B[0m';
  }
}

class _Outcome {
  const _Outcome(this.line, {required this.ok, this.timedOut = false});

  final String line;
  final bool ok;
  final bool timedOut;
}
