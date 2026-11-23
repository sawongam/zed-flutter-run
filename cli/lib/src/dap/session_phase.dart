import '../common/logger.dart';

/// Where the proxy session is in its life. Moves forward only.
///
/// - [starting]: constructed, `run()` not called yet.
/// - [running]: serving the editor and the adapter.
/// - [stopping]: a `terminate`, `disconnect` or shutdown was requested; the
///   graceful stop is under way (see `ShutdownCoordinator` for which one).
/// - [finishing]: the final teardown (cleanup, tree kill, channels) runs.
/// - [finished]: the exit code is available.
enum SessionPhase { starting, running, stopping, finishing, finished }

/// Holds the current [SessionPhase] and is the only place that decides which
/// transitions are legal. An illegal one is logged and ignored (and trips an
/// assertion in debug builds when [strict] is set).
class SessionPhaseMachine {
  SessionPhaseMachine({Logger? logger, this.strict = false})
    : _log = logger ?? Logger.silent();

  /// Legal moves. A session may skip [SessionPhase.stopping] (a crash or a
  /// startup failure finishes directly) but never move backwards.
  static const Map<SessionPhase, Set<SessionPhase>> legal = {
    SessionPhase.starting: {SessionPhase.running, SessionPhase.finishing},
    SessionPhase.running: {SessionPhase.stopping, SessionPhase.finishing},
    SessionPhase.stopping: {SessionPhase.finishing},
    SessionPhase.finishing: {SessionPhase.finished},
    SessionPhase.finished: <SessionPhase>{},
  };

  final Logger _log;
  final bool strict;
  SessionPhase _phase = SessionPhase.starting;

  SessionPhase get phase => _phase;

  /// The final teardown has begun (or is done).
  bool get isFinishing => _phase.index >= SessionPhase.finishing.index;

  bool get isFinished => _phase == SessionPhase.finished;

  /// A stop was requested: moves [SessionPhase.running] to
  /// [SessionPhase.stopping]. Later or repeated requests (a `disconnect` after
  /// a `terminate`, say) are expected and change nothing.
  void beginStopping() {
    if (_phase == SessionPhase.running) transition(SessionPhase.stopping);
  }

  /// Moves to [next]. Returns true when the phase changed; moving to the
  /// current phase is a quiet no-op, anything else illegal is reported.
  bool transition(SessionPhase next) {
    if (next == _phase) return false;
    if (legal[_phase]!.contains(next)) {
      _phase = next;
      return true;
    }
    _log.warn('Illegal session phase change ${_phase.name} -> ${next.name}.');
    assert(!strict, 'Illegal session phase change $_phase -> $next');
    return false;
  }
}
