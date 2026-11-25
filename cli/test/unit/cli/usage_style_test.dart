import 'package:flutter_run/src/cli/usage_style.dart';
import 'package:flutter_run/src/common/style.dart';
import 'package:test/test.dart';

const String _usage = '''
Does things.

Usage: flutter_run <command> [arguments]

Global options:
-h, --help               Print this usage information.
    --project=<dir>      Project directory.

Available commands:
  devtools   Open DevTools (pages: inspector,
 memory).

Exit codes:
  0    Success.
  130  Interrupted (Ctrl+C).

Run "flutter_run help <command>" for more information about a command.''';

String _strip(String s) => s.replaceAll(RegExp('\x1B\\[[0-9;]*m'), '');

void main() {
  const on = Style(true);

  test('a plain style leaves the text unchanged', () {
    expect(styleUsage(_usage, Style.plain), _usage);
  });

  test('colour never changes the visible text', () {
    expect(_strip(styleUsage(_usage, on)), _usage);
  });

  test('colours headings, flags, command names and exit codes', () {
    final lines = styleUsage(_usage, on).split('\n');
    expect(lines, contains(on.heading('Global options:')));
    expect(
      lines,
      contains(
        '${on.heading('Usage:')} '
        '${on.bold('flutter_run <command> [arguments]')}',
      ),
    );
    expect(lines.any((l) => l.startsWith(on.cyan('-h, --help'))), isTrue);
    expect(lines.any((l) => l.contains(on.cyan('--project=<dir>'))), isTrue);
    expect(
      lines,
      contains(
        '  ${on.cyan('devtools')}   Open DevTools (pages: '
        'inspector,',
      ),
    );
    expect(lines, contains(' memory).'));
    expect(lines, contains('  ${on.cyan('130')}  Interrupted (Ctrl+C).'));
    expect(
      lines.last,
      on.dim(
        'Run "flutter_run help <command>" for more information about a '
        'command.',
      ),
    );
  });
}
