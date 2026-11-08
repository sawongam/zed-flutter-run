import 'package:flutter_run/src/dap/messages.dart';
import 'package:test/test.dart';

void main() {
  group('DapMessage', () {
    test('reads the common fields without copying', () {
      final raw = <String, Object?>{
        'seq': 3,
        'type': 'request',
        'command': 'launch',
        'arguments': {'program': 'a'},
        'vendorExtension': 42,
      };
      final m = DapMessage(raw);
      expect(m.seq, 3);
      expect(m.type, 'request');
      expect(m.command, 'launch');
      expect(m.isRequest, isTrue);
      expect(m.isResponse, isFalse);
      expect(m.isEvent, isFalse);
      expect(m.arguments, {'program': 'a'});
      expect(identical(m.raw, raw), isTrue);
      expect(m.raw['vendorExtension'], 42);
    });

    test('reads responses and events', () {
      final response = DapMessage({
        'seq': 1,
        'type': 'response',
        'request_seq': 9,
        'success': false,
        'command': 'attach',
        'body': {'error': 1},
      });
      expect(response.isResponse, isTrue);
      expect(response.requestSeq, 9);
      expect(response.success, isFalse);
      expect(response.failed, isTrue);
      expect(response.body, {'error': 1});

      final event = DapMessage({'type': 'event', 'event': 'output'});
      expect(event.isEvent, isTrue);
      expect(event.event, 'output');
      expect(event.failed, isFalse);
    });

    test('missing or malformed parts read as empty, never throw', () {
      final m = DapMessage({'type': 'event', 'body': 'not an object'});
      expect(m.body, isEmpty);
      expect(m.arguments, isEmpty);
      expect(m.seq, isNull);
      expect(m.command, isNull);
    });

    test('the constants match the protocol names', () {
      expect(DapCommands.hotReload, 'hotReload');
      expect(DapCommands.hotRestart, 'hotRestart');
      expect(DapEvents.debuggerUris, 'dart.debuggerUris');
      expect(DapEvents.flutterAppStarted, 'flutter.appStarted');
    });
  });

  group('makeErrorResponse', () {
    test('is a failed response with a user-visible error', () {
      final r = makeErrorResponse(
        requestSeq: 4,
        command: 'attach',
        message: 'Fix it',
        seq: 77,
      );
      expect(r['success'], isFalse);
      expect(r['request_seq'], 4);
      expect(r['message'], 'Fix it');
      final error = (r['body']! as Map)['error']! as Map;
      expect(error['showUser'], isTrue);
      expect(error['format'], 'Fix it');
    });
  });
}
