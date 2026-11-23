import 'dart:convert';

import 'package:flutter_run/src/init/jsonc.dart';
import 'package:test/test.dart';

void main() {
  test('comments and trailing commas are blanked, offsets kept', () {
    const text = '[ // a\n  {"x": "//not a comment", /* b */ "y": 1,},\n]';
    final blanked = blankJsonc(text);
    expect(blanked.length, text.length);
    expect(jsonDecode(blanked), [
      {'x': '//not a comment', 'y': 1},
    ]);
  });

  test('escaped quotes do not end a string', () {
    expect(decodeJsonc(r'{"a": "q\" // x"}'), {'a': 'q" // x'});
  });

  test('a BOM is accepted', () {
    expect(decodeJsonc('﻿[1]'), [1]);
  });

  test('invalid text still throws', () {
    expect(() => decodeJsonc('[1'), throwsFormatException);
  });

  group('appendToJsoncArray', () {
    const element = '{\n  "a": 1\n}\n';

    test('empty array', () {
      expect(jsonDecode(appendToJsoncArray('[]', element)!), [
        {'a': 1},
      ]);
    });

    test('keeps comments and adds a comma', () {
      const text = '// Zed keymap\n[\n  {"b": 2} // last\n]\n';
      final out = appendToJsoncArray(text, element)!;
      expect(out, startsWith('// Zed keymap\n'));
      expect(out, contains('// last'));
      expect(decodeJsonc(out), [
        {'b': 2},
        {'a': 1},
      ]);
      expect(out, endsWith(']\n'));
    });

    test('after a trailing comma no second comma is added', () {
      final out = appendToJsoncArray('[\n  {"b": 2},\n]', element)!;
      expect(decodeJsonc(out), hasLength(2));
      expect(out, isNot(contains(',,')));
    });

    test('a bracket inside a trailing comment is ignored', () {
      expect(decodeJsonc(appendToJsoncArray('[1]\n// ]', '2')!), [1, 2]);
    });

    test('not an array', () {
      expect(appendToJsoncArray('{"a": 1}', element), isNull);
    });
  });
}
