import 'dart:convert';

import 'package:flutter_run/src/control/session_info.dart';
import 'package:flutter_run/src/control/session_paths.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('SessionInfo', () {
    test('round trip incl. optional keys', () {
      final info = sessionInfo().copyWith(
        vmServiceUri: 'ws://127.0.0.1:1/a=/ws',
      );
      final decoded = SessionInfo.fromJson(
        jsonDecode(jsonEncode(info.toJson())) as Map<String, Object?>,
      );
      expect(decoded.toJson(), info.toJson());
      expect(decoded.startedAt, DateTime.utc(2026, 11, 3, 12));
      expect(decoded.vmServiceUri, 'ws://127.0.0.1:1/a=/ws');
      expect(decoded.appStarted, isTrue);
    });

    test('unknown optional keys are omitted until known', () {
      final json = sessionInfo(deviceId: null).toJson();
      expect(json.containsKey('deviceId'), isFalse);
      expect(json.containsKey('vmServiceUri'), isFalse);
      expect(json['version'], 1);
      expect(json['startedAt'], '2026-11-03T12:00:00.000Z');
    });

    test('unknown keys are ignored', () {
      final json = {...sessionInfo().toJson(), 'future': 1};
      expect(SessionInfo.fromJson(json).pid, 100);
    });

    test('version 2 and missing version are rejected', () {
      expect(
        () => SessionInfo.fromJson({...sessionInfo().toJson(), 'version': 2}),
        throwsFormatException,
      );
      expect(
        () => SessionInfo.fromJson(
          {...sessionInfo().toJson()}..remove('version'),
        ),
        throwsFormatException,
      );
    });

    test('mistyped and missing keys are rejected', () {
      for (final key in ['pid', 'port', 'token', 'projectRoot', 'startedAt']) {
        expect(
          () => SessionInfo.fromJson({...sessionInfo().toJson()}..remove(key)),
          throwsFormatException,
          reason: key,
        );
      }
      expect(
        () => SessionInfo.fromJson({...sessionInfo().toJson(), 'pid': '1'}),
        throwsFormatException,
      );
      expect(
        () => SessionInfo.fromJson({...sessionInfo().toJson(), 'mode': 3}),
        throwsFormatException,
      );
      expect(
        () =>
            SessionInfo.fromJson({...sessionInfo().toJson(), 'startedAt': 'x'}),
        throwsFormatException,
      );
    });

    test('copyWith changes only the given fields', () {
      final a = sessionInfo();
      final b = a.copyWith(appStarted: false, mode: 'profile');
      expect(b.appStarted, isFalse);
      expect(b.mode, 'profile');
      expect(b.pid, a.pid);
      expect(b.token, a.token);
    });
  });

  group('paths', () {
    test(
      'file name is <pid>.json',
      () => expect(sessionFileName(123), '123.json'),
    );

    test('sessions directory is under the state base', () {
      expect(sessionsDirectory(linuxEnv(stateDir: '/s')), '/s/sessions');
    });
  });
}
