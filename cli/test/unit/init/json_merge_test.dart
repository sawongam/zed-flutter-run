import 'dart:convert';

import 'package:flutter_run/src/init/json_merge.dart';
import 'package:test/test.dart';

Map<String, Object?> e(String label, [Object? extra]) => {
  'label': label,
  'x': extra,
};

void main() {
  test('absent file is created: 2-space, LF, trailing newline', () {
    final r = mergeLabeledArray(null, [e('a'), e('b')]);
    expect(r, isA<MergeCreated>());
    final content = (r as MergeCreated).content;
    expect(content, endsWith(']\n'));
    expect(content, contains('\n  {\n    "label": "a"'));
    expect(content, isNot(contains('\r')));
    expect((jsonDecode(content) as List<Object?>), hasLength(2));
  });

  test('existing labels are kept, missing appended, order preserved', () {
    final existing = jsonEncode([e('mine', 1), e('a', 'old')]);
    final r =
        mergeLabeledArray(existing, [e('a', 'new'), e('b')]) as MergeUpdated;
    expect(r.added, 1);
    expect(r.kept, 1);
    final list = jsonDecode(r.content) as List<Object?>;
    expect(list.map((x) => (x! as Map<String, Object?>)['label']), [
      'mine',
      'a',
      'b',
    ]);
    expect((list[1]! as Map<String, Object?>)['x'], 'old');
    expect(r.content, endsWith('\n'));
  });

  test('nothing to add leaves the text untouched', () {
    const existing = '[{"label":"a"}]';
    final r = mergeLabeledArray(existing, [e('a')]) as MergeUpdated;
    expect(r.added, 0);
    expect(r.kept, 1);
    expect(r.content, existing);
  });

  test('non-map entries and entries without labels are kept', () {
    final r = mergeLabeledArray('[1, {"foo": 2}]', [e('a')]) as MergeUpdated;
    expect(r.added, 1);
    expect(r.kept, 0);
    expect((jsonDecode(r.content) as List<Object?>), hasLength(3));
  });

  test('duplicate labels in additions are added once', () {
    final r = mergeLabeledArray('[]', [e('a'), e('a')]) as MergeUpdated;
    expect(r.added, 1);
  });

  for (final entry in {
    'line comment': '// hi\n[]',
    'block comment': '/* x */ []',
    'trailing comma': '[{"label":"a"},]',
  }.entries) {
    test('needs manual: ${entry.key}', () {
      final r = mergeLabeledArray(entry.value, [e('a')]);
      expect(r, isA<MergeNeedsManual>());
      final m = r as MergeNeedsManual;
      expect(m.reason, contains('comments or trailing commas'));
      expect(jsonDecode(m.snippet), isA<List<Object?>>());
    });
  }

  test('empty and whitespace-only files are treated as absent', () {
    for (final text in ['', '  \n']) {
      expect(mergeLabeledArray(text, [e('a')]), isA<MergeCreated>());
    }
  });

  test('UTF-8 BOM is stripped before parsing', () {
    final r =
        mergeLabeledArray('\uFEFF[{"label":"a"}]', [e('a'), e('b')])
            as MergeUpdated;
    expect(r.added, 1);
    expect(r.kept, 1);
    expect(r.content.startsWith('\uFEFF'), isFalse);
  });

  test('plain garbage says not valid JSON', () {
    final r = mergeLabeledArray('not json', [e('a')]) as MergeNeedsManual;
    expect(r.reason, 'it is not valid JSON');
  });

  test('root object needs manual', () {
    final r = mergeLabeledArray('{"a": 1}', [e('a')]);
    expect(r, isA<MergeNeedsManual>());
    expect((r as MergeNeedsManual).reason, contains('not a JSON array'));
  });

  test('isStrictJson', () {
    expect(isStrictJson('[]'), isTrue);
    expect(isStrictJson('[1,]'), isFalse);
    expect(isStrictJson('// c\n[]'), isFalse);
    expect(isStrictJson(''), isFalse);
  });
}
