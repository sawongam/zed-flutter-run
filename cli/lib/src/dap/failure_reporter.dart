import 'initialize_watchdog.dart';
import 'messages.dart';
import 'notices.dart';
import 'stderr_tail.dart';

/// Tells the editor why the adapter never became ready or died, using the
/// adapter's last stderr lines. It only reports; the proxy ends the session.
class FailureReporter {
  FailureReporter({
    required this.watchdog,
    required this.stderrTail,
    required this._send,
    required this._nextSeq,
    required this._notice,
  });

  final InitializeWatchdog watchdog;
  final StderrTail stderrTail;
  final void Function(DapJson message) _send;
  final int Function() _nextSeq;
  final void Function(String text, NoticeLevel level) _notice;

  /// The adapter did not answer `initialize`: fail that request and show the
  /// reason with the adapter's last message. Returns false when the start-up
  /// was already answered (nothing is sent).
  bool startupFailed(String reason) {
    if (watchdog.answered) return false;
    watchdog.markAnswered();
    final lastLine = stderrTail.last;
    final text = StringBuffer(reason)
      ..write(
        ' Check that "flutter debug_adapter" works in a terminal, then try '
        'again.',
      );
    if (lastLine != null) {
      text.write(' The last message from it was: $lastLine');
    }
    _failInitialize(text.toString());
    _send(
      makeOutputEvent(
        formatNotice(text.toString(), NoticeLevel.error),
        category: 'stderr',
        seq: _nextSeq(),
      ),
    );
    return true;
  }

  /// The adapter exited without being asked to: fail a pending `initialize`,
  /// show its stderr, tell the editor the program ended.
  void adapterCrashed(int code) {
    final tail = stderrTail.text;
    if (watchdog.isPending) {
      watchdog.markAnswered();
      _failInitialize(
        tail.isEmpty
            ? 'The Flutter debug adapter stopped before it was ready '
                  '(exit code $code).'
            : tail.split('\n').last,
      );
    }
    if (tail.isNotEmpty) {
      _send(makeOutputEvent('$tail\n', category: 'stderr', seq: _nextSeq()));
    }
    _notice(
      'The Flutter debug adapter stopped unexpectedly (exit code $code). '
      'Start the debug session again.',
      NoticeLevel.error,
    );
    _send(<String, Object?>{
      'seq': _nextSeq(),
      'type': 'event',
      'event': DapEvents.terminated,
      'body': <String, Object?>{},
    });
  }

  /// Answers a client request the proxy refused, with an error the editor
  /// shows to the user.
  void requestRejected(DapMessage request, String reason) {
    final seq = request.seq;
    _send(
      makeErrorResponse(
        requestSeq: seq is int ? seq : 0,
        command: '${request.command}',
        message: reason,
        seq: _nextSeq(),
      ),
    );
    _notice(reason, NoticeLevel.error);
  }

  /// Answers a client request that failed inside the proxy.
  void requestFailed(DapMessage request, Object error) {
    final command = '${request.command}';
    final seq = request.seq;
    _send(
      makeResponse(
        requestSeq: seq is int ? seq : 0,
        command: command,
        success: false,
        message:
            'The flutter_run proxy could not handle the "$command" request '
            '($error). Check the log file and try again.',
        seq: _nextSeq(),
      ),
    );
    _notice(
      'The "$command" request failed inside flutter_run: $error',
      NoticeLevel.error,
    );
  }

  /// The failure for a hot action this adapter kind cannot do.
  DapJson hotUnsupported(String command, Object? requestSeq) => makeResponse(
    requestSeq: requestSeq is int ? requestSeq : 0,
    command: command == DapCommands.restart ? command : DapCommands.hotRestart,
    success: false,
    message:
        'Hot restart is only available for Flutter apps. Stop and start the '
        'program instead.',
    seq: _nextSeq(),
  );

  void _failInitialize(String message) {
    final seq = watchdog.seq;
    _send(
      makeResponse(
        requestSeq: seq is int ? seq : 0,
        command: DapCommands.initialize,
        success: false,
        message: message,
        seq: _nextSeq(),
      ),
    );
  }
}
