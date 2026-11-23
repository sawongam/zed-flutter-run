import 'dart:async';

import '../common/clock.dart';
import '../common/json_types.dart';
import 'launch_rewriter.dart';
import 'messages.dart';

/// One injected request still waiting for the adapter's answer.
typedef _Pending = ({Completer<DapJson> response, Timer? timer});

/// Allocates sequence numbers for injected requests and swallows their
/// responses. Client messages are never renumbered; injected and synthetic
/// numbers start at [firstSeq], far above anything an editor sends.
class InjectedRequests {
  static const int firstSeq = 1000000000;

  /// How many timed-out requests are remembered so their late answers are
  /// still swallowed.
  static const int lateSetLimit = 64;

  int _nextInjected = firstSeq;
  int _nextSynthetic = firstSeq;
  final Map<int, _Pending> _pending = {};
  final List<int> _late = [];

  /// Sends a new request through [send] and completes with the adapter's
  /// response (including `success:false`). With a [timeout] and no answer in
  /// time it fails with a [TimeoutException] and a late answer is swallowed.
  Future<DapJson> dispatch(
    String command,
    Json? arguments,
    Duration? timeout, {
    required Clock clock,
    required void Function(DapJson message) send,
  }) {
    final seq = _nextInjected++;
    final response = Completer<DapJson>();
    final timer = timeout == null
        ? null
        : clock.timer(timeout, () {
            if (_pending.remove(seq) == null) return;
            _rememberLate(seq);
            response.completeError(
              TimeoutException('No response to $command', timeout),
            );
          });
    _pending[seq] = (response: response, timer: timer);
    send(<String, Object?>{
      'seq': seq,
      'type': 'request',
      'command': command,
      'arguments': ?arguments,
    });
    return response.future;
  }

  /// Returns true when [adapterResponse] answers an injected request (pending
  /// or timed out); the caller must not forward it.
  bool consumeResponse(DapJson adapterResponse) {
    final requestSeq = adapterResponse['request_seq'];
    if (requestSeq is! int) return false;
    final pending = _pending.remove(requestSeq);
    if (pending != null) {
      pending.timer?.cancel();
      pending.response.complete(adapterResponse);
      return true;
    }
    return _late.remove(requestSeq);
  }

  bool clientSeqCollides(DapJson clientRequest) {
    final seq = clientRequest['seq'];
    return seq is int && seq >= firstSeq;
  }

  /// Fails every request still waiting for an answer. Their answers, should
  /// they still come, are swallowed like late ones.
  void failPending(Object error) {
    final pending = Map.of(_pending);
    _pending.clear();
    pending.forEach((seq, p) {
      p.timer?.cancel();
      _rememberLate(seq);
      p.response.completeError(error);
    });
  }

  void _rememberLate(int seq) {
    _late.add(seq);
    while (_late.length > lateSetLimit) {
      _late.removeAt(0);
    }
  }

  /// Sequence numbers for client-bound synthetic messages.
  int nextSyntheticSeq() => _nextSynthetic++;
}

/// Injected requests that only some adapters support, per adapter kind. A
/// command missing from [gatedInjections] is never refused here.
const Map<DapKind, Set<String>> supportedInjections = {
  DapKind.flutter: {DapCommands.hotReload, DapCommands.hotRestart},
  DapKind.dart: {DapCommands.hotReload},
};

/// Every command that [supportedInjections] decides about.
const Set<String> gatedInjections = {
  DapCommands.hotReload,
  DapCommands.hotRestart,
};

/// Whether an adapter of [kind] can take the injected [command].
bool injectionSupported(DapKind kind, String command) =>
    !gatedInjections.contains(command) ||
    (supportedInjections[kind]?.contains(command) ?? false);
