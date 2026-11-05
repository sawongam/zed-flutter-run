// A tiny stand-in for `flutter debug_adapter`, started by dap_command_test
// through a fake `bin/flutter` script. Not a test itself.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

void send(Map<String, Object?> message) {
  final body = utf8.encode(jsonEncode(message));
  stdout
    ..add(utf8.encode('Content-Length: ${body.length}\r\n\r\n'))
    ..add(body);
}

var _seq = 1;

void response(Map<String, Object?> request, [Map<String, Object?>? body]) =>
    send({
      'seq': _seq++,
      'type': 'response',
      'request_seq': request['seq'],
      'success': true,
      'command': request['command'],
      'body': ?body,
    });

void event(String name, [Map<String, Object?> body = const {}]) =>
    send({'seq': _seq++, 'type': 'event', 'event': name, 'body': body});

Future<void> main(List<String> args) async {
  final buffer = <int>[];
  await for (final chunk in stdin) {
    buffer.addAll(chunk);
    while (true) {
      final text = latin1.decode(buffer);
      final end = text.indexOf('\r\n\r\n');
      if (end < 0) break;
      final length = int.parse(
        RegExp(r'Content-Length: (\d+)').firstMatch(text)!.group(1)!,
      );
      if (buffer.length < end + 4 + length) break;
      final request =
          jsonDecode(utf8.decode(buffer.sublist(end + 4, end + 4 + length)))
              as Map<String, Object?>;
      buffer.removeRange(0, end + 4 + length);
      if (request['type'] != 'request') continue;
      switch (request['command']) {
        case 'initialize':
          response(request, {'supportsTerminateRequest': true});
        case 'launch' || 'attach':
          final record = Platform.environment['FAKE_ADAPTER_RECORD'];
          if (record != null) {
            File(record).writeAsStringSync(jsonEncode(request['arguments']));
          }
          response(request);
          event('initialized');
          if (Platform.environment['FAKE_ADAPTER_STALL'] != '1') {
            event('flutter.appStart', {
              'appId': 'app1',
              'deviceId': 'fake-device',
              'mode': Platform.environment['FAKE_ADAPTER_MODE'] ?? 'debug',
            });
            event('dart.debuggerUris', {
              'vmServiceUri': 'ws://127.0.0.1:9/abc=/ws',
            });
            event('flutter.appStarted');
          }
        case 'terminate':
          response(request);
          event('terminated');
          await stdout.flush();
          exit(0);
        case 'disconnect':
          response(request);
          await stdout.flush();
          exit(0);
        default:
          response(request);
      }
    }
  }
}
