import 'dart:async';

import '../common/json_types.dart';
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
/// responses (ADR 0006 D3: client messages are never renumbered).
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

  /// Sequence numbers for client-bound synthetic messages.
  int nextSyntheticSeq() => _nextSynthetic++;
}
