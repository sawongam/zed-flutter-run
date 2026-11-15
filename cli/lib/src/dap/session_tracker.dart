import 'dart:async';

import 'device_hints.dart';
import 'launch_rewriter.dart';
import 'messages.dart';
import 'notices.dart';
import 'proxy_state.dart';

/// Follows what the adapter reports (app ids, VM service address, whether the
/// app started or ended) and publishes it as [ProxyState] and [ProxyEvent]s.
class SessionTracker {
  SessionTracker({
    required DapKind kind,
    required void Function(String text, NoticeLevel level) onNotice,
    required void Function() onProcessActivity,
  }) : _kind = kind,
       _onNotice = onNotice,
       _onProcessActivity = onProcessActivity,
       _state = const ProxyState(request: DapCommands.launch);

  final DapKind _kind;
  final void Function(String text, NoticeLevel level) _onNotice;

  /// Called when the adapter's process tree may have changed.
  final void Function() _onProcessActivity;
  final StreamController<ProxyEvent> _events =
      StreamController<ProxyEvent>.broadcast();

  ProxyState _state;
  bool _seenDebuggerUris = false;
  bool _deviceHintShown = false;

  ProxyState get state => _state;

  Stream<ProxyEvent> get events => _events.stream;

  /// Records the kind of the client's request even when it was refused.
  void requestSeen(String command) {
    if (_state.request == command) return;
    _state = _state.copyWith(request: command);
    _emit(StateChanged(_state));
  }

  /// Records the client's rewritten `launch` or `attach`.
  void launchRewritten(String command, RewriteResult result) {
    _state = _state.copyWith(request: command, deviceId: result.deviceId);
    _emit(LaunchRewritten(command, result));
    _emit(StateChanged(_state));
  }

  /// Shows the device hint when a failed `launch`/`attach` explains one.
  void launchFailed(DapMessage response) {
    final error = response.body['error'];
    final format = error is Map ? error['format'] : null;
    _maybeDeviceHint('${response.raw['message'] ?? ''}\n${format ?? ''}');
  }

  /// Updates the state from an adapter event (already forwarded).
  void onEvent(DapMessage event) {
    final fields = event.body;
    switch (event.event) {
      case DapEvents.output:
        final text = fields['output'];
        if (text is String) _maybeDeviceHint(text);
      case DapEvents.debuggerUris:
        final uri = fields['vmServiceUri'];
        if (uri is String) {
          final isFirst = !_seenDebuggerUris;
          _seenDebuggerUris = true;
          // The Dart adapter never sends flutter.appStarted; its debugger
          // URIs (debug mode only) mean the program is running.
          final startsNow = _kind == DapKind.dart && !_state.appStarted;
          _setState(
            _state.copyWith(
              vmServiceUri: uri,
              appStarted: startsNow ? true : null,
            ),
          );
          _emit(DebuggerUris(uri, isFirst: isFirst));
          if (startsNow) _emit(AppStarted());
          _onProcessActivity();
        }
      case DapEvents.thread:
        _onProcessActivity();
      case DapEvents.flutterAppStart:
        _onProcessActivity();
        final appId = fields['appId'];
        final deviceId = fields['deviceId'];
        final mode = fields['mode'];
        _setState(
          _state.copyWith(
            appId: appId is String ? appId : null,
            deviceId: deviceId is String ? deviceId : null,
            mode: mode is String ? mode : null,
          ),
        );
      case DapEvents.flutterAppStarted:
        if (!_state.appStarted) {
          _setState(_state.copyWith(appStarted: true));
          _emit(AppStarted());
        }
      case DapEvents.terminated || DapEvents.exited:
        markEnded();
    }
  }

  void markEnded() {
    if (_state.ended) return;
    _setState(_state.copyWith(ended: true));
    _emit(SessionEnded());
  }

  /// Closes the event stream.
  void close() {
    if (!_events.isClosed) unawaited(_events.close());
  }

  void _maybeDeviceHint(String text) {
    if (_deviceHintShown) return;
    final hint = deviceHintFor(text);
    if (hint == null) return;
    _deviceHintShown = true;
    _onNotice(hint, NoticeLevel.warn);
  }

  void _setState(ProxyState next) {
    _state = next;
    _emit(StateChanged(next));
  }

  void _emit(ProxyEvent event) {
    if (!_events.isClosed) _events.add(event);
  }
}
