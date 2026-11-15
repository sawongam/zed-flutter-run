import 'dart:async';

import '../common/clock.dart';
import '../common/json_types.dart';
import 'launch_rewriter.dart';
import 'messages.dart';

/// A request the proxy sends to the adapter on its own.
class InjectedRequest {
  InjectedRequest._(this.seq, this.message, this.response);

  final int seq;

  /// The message to send to the adapter.
  final DapJson message;

  /// Completes with the adapter's response (including `success:false`).
  final Future<DapJson> response;
}

/// Allocates sequence numbers for injected requests and swallows their
/// responses. Client messages are never renumbered; injected and synthetic
/// numbers start at [firstSeq], far above anything an editor sends.
class InjectedRequests {
  InjectedRequests({this.firstSeq = 1000000000})
    : _nextInjected = firstSeq,
      _nextSynthetic = firstSeq;

  static const int lateSetLimit = 64;

  final int firstSeq;
  int _nextInjected;
  int _nextSynthetic;
  final Map<int, Completer<DapJson>> _pending = {};
  final List<int> _late = [];

  InjectedRequest create(String command, Json? arguments) {
    final seq = _nextInjected++;
    final completer = Completer<DapJson>();
    _pending[seq] = completer;
    final message = <String, Object?>{
      'seq': seq,
      'type': 'request',
      'command': command,
      'arguments': ?arguments,
    };
    return InjectedRequest._(seq, message, completer.future);
  }

  /// Returns true when [adapterResponse] answers an injected request (pending
  /// or timed out); the caller must not forward it.
  bool consumeResponse(DapJson adapterResponse) {
    final requestSeq = adapterResponse['request_seq'];
    if (requestSeq is! int) return false;
    final completer = _pending.remove(requestSeq);
    if (completer != null) {
      completer.complete(adapterResponse);
      return true;
    }
    return _late.remove(requestSeq);
  }

  /// Keeps [seq] in a bounded set so a late response is still swallowed.
  void markTimedOut(int seq) {
    if (_pending.remove(seq) == null) return;
    _late.add(seq);
    while (_late.length > lateSetLimit) {
      _late.removeAt(0);
    }
  }

  bool clientSeqCollides(DapJson clientRequest) {
    final seq = clientRequest['seq'];
    return seq is int && seq >= firstSeq;
  }

  final Set<Completer<DapJson>> _inFlight = {};

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
    final request = create(command, arguments);
    final result = Completer<DapJson>();
    _inFlight.add(result);
    Timer? timer;
    // The response is forwarded through [result]; this chain only completes it.
    unawaited(
      request.response.then<void>((response) {
        timer?.cancel();
        _inFlight.remove(result);
        if (!result.isCompleted) result.complete(response);
      }),
    );
    if (timeout != null) {
      timer = clock.timer(timeout, () {
        if (result.isCompleted) return;
        markTimedOut(request.seq);
        _inFlight.remove(result);
        result.completeError(
          TimeoutException('No response to $command', timeout),
        );
      });
    }
    send(request.message);
    return result.future;
  }

  /// Fails every request still waiting for an answer.
  void failPending(Object error) {
    for (final pending in List.of(_inFlight)) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    _inFlight.clear();
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
