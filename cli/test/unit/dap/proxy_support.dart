import 'package:flutter_run/src/common/clock.dart';
import 'package:flutter_run/src/dap/launch_rewriter.dart';
import 'package:flutter_run/src/dap/messages.dart';
import 'package:flutter_run/src/dap/proxy.dart';
import 'package:flutter_run/src/dap/proxy_state.dart';

import 'fakes.dart';

export 'fakes.dart';

const int injectedBase = 1000000000;

/// Arguments of an `attach` the proxy accepts.
const Map<String, Object?> attachArgs = {
  'vmServiceUri': 'http://127.0.0.1:1/a=/',
};

class Harness {
  Harness({
    DapKind kind = DapKind.flutter,
    String? saved,
    ProxyOptions? options,
    Clock clock = const SystemClock(),
  }) {
    client = FakeChannel(onSend: (m) => order.add('client:${_label(m)}'));
    adapter = FakeAdapter(onSend: (m) => order.add('adapter:${_label(m)}'));
    proxy = DapProxy(
      client: client,
      adapter: adapter,
      options: options ?? ProxyOptions(kind: kind),
      clock: clock,
      rewriter: LaunchRewriter(
        kind: kind,
        cwd: '/proj',
        environment: const {},
        savedDevice: () => saved,
      ),
      onShutdownStarted: () async => order.add('hook:started'),
      onShutdownCleanup: () async => order.add('hook:cleanup'),
    );
    proxy.events.listen(events.add);
    proxy.run().then((c) => exitCode = c);
  }

  late final FakeChannel client;
  late final FakeAdapter adapter;
  late final DapProxy proxy;
  final List<String> order = [];
  final List<ProxyEvent> events = [];
  int? exitCode;

  static String _label(DapJson m) {
    final type = m['type'];
    if (type == 'event') return '${m['event']}';
    return '${m['command']}';
  }

  /// Sends [message] from the client side.
  void fromClient(DapJson message) => client.incoming.add(message);

  void request(int seq, String command, [Object? arguments]) => fromClient({
    'seq': seq,
    'type': 'request',
    'command': command,
    'arguments': ?arguments,
  });
}
