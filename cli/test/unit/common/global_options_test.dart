import 'package:args/command_runner.dart';
import 'package:flutter_run/src/common/global_options.dart';
import 'package:test/test.dart';

class _Cmd extends Command<int> {
  _Cmd() {
    GlobalOptions.addTo(argParser);
  }
  GlobalOptions? seen;
  @override
  String get name => 'c';
  @override
  String get description => 'test';
  @override
  int run() {
    seen = GlobalOptions.of(this);
    return 0;
  }
}

class _Bare extends Command<int> {
  GlobalOptions? seen;
  @override
  String get name => 'bare';
  @override
  String get description => 'test';
  @override
  int run() {
    seen = GlobalOptions.of(this);
    return 0;
  }
}

void main() {
  late CommandRunner<int> runner;
  late _Cmd cmd;
  late _Bare bare;
  setUp(() {
    runner = CommandRunner<int>('t', 'test');
    GlobalOptions.addTo(runner.argParser);
    cmd = _Cmd();
    bare = _Bare();
    runner
      ..addCommand(cmd)
      ..addCommand(bare);
  });

  test('registers the three options with -v', () {
    expect(
      runner.argParser.options.keys,
      containsAll(['verbose', 'project', 'flutter-sdk']),
    );
    expect(runner.argParser.findByAbbreviation('v'), isNotNull);
  });

  test('defaults', () async {
    await runner.run(['c']);
    expect(cmd.seen!.verbose, isFalse);
    expect(cmd.seen!.project, isNull);
    expect(cmd.seen!.flutterSdk, isNull);
  });

  test('values before the command (runner level)', () async {
    await runner.run(['-v', '--project', '/p', '--flutter-sdk', '/s', 'c']);
    expect(cmd.seen!.verbose, isTrue);
    expect(cmd.seen!.project, '/p');
    expect(cmd.seen!.flutterSdk, '/s');
  });

  test('values after the command; command wins', () async {
    await runner.run([
      '--project',
      '/g',
      'c',
      '--project',
      '/own',
      '--verbose',
    ]);
    expect(cmd.seen!.verbose, isTrue);
    expect(cmd.seen!.project, '/own');
  });

  test('commands that did not register the options still work', () async {
    await runner.run(['--project', '/g', 'bare']);
    expect(bare.seen!.project, '/g');
  });
}
