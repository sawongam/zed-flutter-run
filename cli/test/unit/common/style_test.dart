import 'package:flutter_run/src/common/style.dart';
import 'package:flutter_run/src/devices/table.dart';
import 'package:test/test.dart';

void main() {
  test('Style adds codes only when enabled', () {
    expect(const Style(true).green('ok'), '\x1B[32mok\x1B[0m');
    expect(const Style(true).error('x'), '\x1B[1;31mx\x1B[0m');
    expect(const Style(true).dim(''), '');
    expect(Style.plain.green('ok'), 'ok');
  });

  group('colorWanted', () {
    bool wanted(bool tty, [Map<String, String> env = const {}]) =>
        colorWanted(isTerminal: tty, environment: env);

    test('follows the terminal by default', () {
      expect(wanted(true), isTrue);
      expect(wanted(false), isFalse);
    });

    test('NO_COLOR wins over everything', () {
      expect(wanted(true, {'NO_COLOR': '1', 'FORCE_COLOR': '1'}), isFalse);
      expect(wanted(true, {'NO_COLOR': ''}), isTrue);
    });

    test('FORCE_COLOR turns colour on for a pipe, 0 does not', () {
      expect(wanted(false, {'FORCE_COLOR': '1'}), isTrue);
      expect(wanted(false, {'FORCE_COLOR': '0'}), isFalse);
    });

    test('TERM=dumb turns it off', () {
      expect(wanted(true, {'TERM': 'dumb'}), isFalse);
    });
  });

  test('formatTable bolds the header without breaking alignment', () {
    final rows = [
      ['Name', 'Id'],
      ['Pixel', 'x'],
    ];
    final plain = formatTable(rows);
    final styled = formatTable(rows, style: const Style(true));
    expect(styled[0], '\x1B[1m${plain[0]}\x1B[0m');
    expect(styled[1], plain[1]);
  });
}
