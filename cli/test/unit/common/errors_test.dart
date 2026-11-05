import 'package:flutter_run/src/common/errors.dart';
import 'package:test/test.dart';

void main() {
  test('exit code values', () {
    expect(ExitCodes.ok, 0);
    expect(ExitCodes.internal, 1);
    expect(ExitCodes.usage, 2);
    expect(ExitCodes.noSession, 3);
    expect(ExitCodes.sessionError, 4);
    expect(ExitCodes.timeout, 5);
    expect(ExitCodes.sdkNotFound, 6);
    expect(ExitCodes.deviceError, 7);
    expect(ExitCodes.projectNotFound, 8);
    expect(ExitCodes.manualActionRequired, 9);
    expect(ExitCodes.externalToolFailed, 10);
    expect(ExitCodes.interrupted, 130);
  });

  test('exceptions map to exit codes', () {
    final cases = <FlutterRunException, int>{
      const FlutterRunException('x'): 1,
      const UsageError('x'): 2,
      const NoSessionException('x'): 3,
      const SessionRequestException('x'): 4,
      const RequestTimeoutException('x'): 5,
      const SdkNotFoundException('x'): 6,
      const DeviceException('x'): 7,
      const ProjectNotFoundException('x'): 8,
      const ManualActionRequired('x'): 9,
      const ExternalToolException('x'): 10,
    };
    cases.forEach((e, code) => expect(e.exitCode, code, reason: '$e'));
  });

  test('message, hint, cause and tried are kept', () {
    const cause = FormatException('bad');
    const e = ExternalToolException('failed', hint: 'Try again.', cause: cause);
    expect(e.toString(), 'failed');
    expect(e.hint, 'Try again.');
    expect(e.cause, cause);
    const s = SdkNotFoundException('none', tried: ['a', 'b']);
    expect(s.tried, ['a', 'b']);
    expect(s, isA<FlutterRunException>());
  });
}
