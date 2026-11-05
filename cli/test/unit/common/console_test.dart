import 'package:flutter_run/src/common/console.dart';
import 'package:test/test.dart';

void main() {
  test('MemoryConsole records output and replays input', () async {
    final c = MemoryConsole(input: ['a', 'b'], interactive: true)
      ..out('o')
      ..err('e');
    expect(c.outLines, ['o']);
    expect(c.errLines, ['e']);
    expect(c.isInteractive, isTrue);
    expect(c.useColor, isFalse);
    expect(await c.readLine(), 'a');
    expect(await c.readLine(), 'b');
    expect(await c.readLine(), isNull);
    expect(MemoryConsole().isInteractive, isFalse);
  });

  test('SystemConsole honours an explicit colour choice', () {
    expect(SystemConsole(color: true).useColor, isTrue);
    expect(SystemConsole(color: false).useColor, isFalse);
  });
}
