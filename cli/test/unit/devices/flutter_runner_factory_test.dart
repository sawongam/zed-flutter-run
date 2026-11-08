import 'dart:async';

import 'package:flutter_run/src/common/errors.dart';
import 'package:flutter_run/src/devices/device_lister.dart';
import 'package:flutter_run/src/devices/flutter_runner_factory.dart';
import 'package:test/test.dart';

void main() {
  FlutterRunnerFactory make(
    FlutterToolExecutor execute, [
    List<String>? seen,
  ]) => createFlutterRunnerFactory(
    currentDirectory: '/cwd',
    resolveExecutable: ({projectDir, explicitSdk}) async {
      seen?.add('$projectDir|$explicitSdk');
      return '/sdk/bin/flutter';
    },
    execute: execute,
  );

  test('resolves in the working directory by default and runs', () async {
    final seen = <String>[];
    Duration? limit;
    final run = await make((
      exe,
      args, {
      workingDirectory,
      required timeout,
    }) async {
      limit = timeout;
      return FlutterToolResult(0, '$exe ${args.join(' ')}', '');
    }, seen)();
    final result = await run(['devices']);
    expect(seen, ['/cwd|null']);
    expect(result.stdout, '/sdk/bin/flutter devices');
    expect(limit, const Duration(seconds: 60));
  });

  test('a timeout becomes a TimeoutException', () async {
    final run = await make(
      (_, _, {workingDirectory, required timeout}) async =>
          throw const ExternalToolException('too slow'),
    )();
    await expectLater(run(['x']), throwsA(isA<TimeoutException>()));
  });

  test('a spawn failure stays an ExternalToolException', () async {
    final run = await make(
      (_, _, {workingDirectory, required timeout}) async =>
          throw ExternalToolException('no', cause: StateError('x')),
    )();
    await expectLater(run(['x']), throwsA(isA<ExternalToolException>()));
  });

  test('an unsafe argument is refused', () async {
    final run = await make(
      (_, _, {workingDirectory, required timeout}) async =>
          throw ArgumentError('bad'),
    )();
    await expectLater(
      run(['x']),
      throwsA(
        isA<ExternalToolException>().having(
          (e) => e.message,
          'message',
          contains('refused'),
        ),
      ),
    );
  });
}
