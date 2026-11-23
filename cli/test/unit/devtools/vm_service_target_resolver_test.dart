import 'package:flutter_run/src/common/errors.dart';
import 'package:flutter_run/src/devtools/vm_service_target_resolver.dart';
import 'package:test/test.dart';

void main() {
  final t0 = DateTime.utc(2026);
  RunningSession s(
    int pid, {
    String? uri,
    int minutes = 0,
    bool dead = false,
  }) => RunningSession(
    vmServiceUri: uri,
    startedAt: t0.add(Duration(minutes: minutes)),
    pid: pid,
    kind: 'flutter',
    unresponsive: dead,
  );

  test('no live session is NoSessionException', () async {
    final r = createVmServiceTargetResolver(
      (_) async => [s(1, uri: 'u', dead: true)],
    );
    await expectLater(r(directory: '/p'), throwsA(isA<NoSessionException>()));
  });

  test('no address yet is a SessionRequestException', () async {
    final r = createVmServiceTargetResolver((_) async => [s(1)]);
    await expectLater(
      r(directory: '/p'),
      throwsA(isA<SessionRequestException>()),
    );
  });

  test('picks the newest session with an address', () async {
    final r = createVmServiceTargetResolver(
      (_) async => [
        s(1, uri: 'old'),
        s(2, uri: 'new', minutes: 5),
        s(3, minutes: 9),
      ],
    );
    final target = await r(directory: '/p');
    expect(target.vmServiceUri, 'new');
    expect(target.sessionPid, 2);
  });
}
