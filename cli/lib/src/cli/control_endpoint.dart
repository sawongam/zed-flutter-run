import '../common/logger.dart';
import '../control/control_protocol.dart';
import '../control/control_server.dart';

/// The part of a running control server that a session needs.
abstract interface class ControlEndpoint {
  int get port;
  String get token;
  Future<void> close();
}

class ServerEndpoint implements ControlEndpoint {
  ServerEndpoint(this._server);

  final ControlServer _server;

  @override
  int get port => _server.port;

  @override
  String get token => _server.token;

  @override
  Future<void> close() => _server.close();
}

/// Starts the control server for a session (`ControlServer.start`).
typedef ControlServerStarter =
    Future<ControlEndpoint> Function({
      required SessionControl control,
      Logger? logger,
    });
