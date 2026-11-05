import 'dart:convert';

import 'package:flutter_run/src/watch/content_hash.dart';
import 'package:test/test.dart';

void main() {
  late Map<String, List<int>?> files;
  late ContentHashTracker tracker;

  setUp(() {
    files = {};
    tracker = ContentHashTracker(
      readFile: (path) async => files[path],
      maxBytes: 16,
    );
  });

  test('first sight is a change; identical rewrite is not', () async {
    files['a'] = utf8.encode('one');
    expect(await tracker.hasChanged('a'), isTrue);
    expect(await tracker.hasChanged('a'), isFalse);
    files['a'] = utf8.encode('one');
    expect(await tracker.hasChanged('a'), isFalse);
  });

  test('different content is a change, then stable', () async {
    files['a'] = utf8.encode('one');
    await tracker.hasChanged('a');
    files['a'] = utf8.encode('two');
    expect(await tracker.hasChanged('a'), isTrue);
    expect(await tracker.hasChanged('a'), isFalse);
    files['a'] = utf8.encode('one');
    expect(await tracker.hasChanged('a'), isTrue);
  });

  test('files are tracked independently', () async {
    files['a'] = utf8.encode('x');
    files['b'] = utf8.encode('x');
    expect(await tracker.hasChanged('a'), isTrue);
    expect(await tracker.hasChanged('b'), isTrue);
  });

  test('deleted file counts once, recreation counts again', () async {
    files['a'] = utf8.encode('one');
    await tracker.hasChanged('a');
    files['a'] = null;
    expect(await tracker.hasChanged('a'), isTrue);
    expect(await tracker.hasChanged('a'), isFalse);
    files['a'] = utf8.encode('one');
    expect(await tracker.hasChanged('a'), isTrue);
  });

  test('a never seen, missing file counts once', () async {
    expect(await tracker.hasChanged('gone'), isTrue);
    expect(await tracker.hasChanged('gone'), isFalse);
  });

  test('big files always count as changed', () async {
    files['big'] = List.filled(17, 1);
    expect(await tracker.hasChanged('big'), isTrue);
    expect(await tracker.hasChanged('big'), isTrue);
    files['big'] = List.filled(16, 1);
    expect(await tracker.hasChanged('big'), isTrue);
    expect(await tracker.hasChanged('big'), isFalse);
  });

  test('a read error counts like a missing file', () async {
    final t = ContentHashTracker(
      readFile: (_) async => throw StateError('boom'),
    );
    expect(await t.hasChanged('a'), isTrue);
    expect(await t.hasChanged('a'), isFalse);
  });

  test('forget makes identical content count as changed again', () async {
    files['a'] = utf8.encode('one');
    await tracker.hasChanged('a');
    tracker.forget('a');
    expect(await tracker.hasChanged('a'), isTrue);
  });

  test('explicit keys share one entry', () async {
    files['A'] = utf8.encode('one');
    files['a'] = utf8.encode('one');
    expect(await tracker.hasChanged('A', key: 'k'), isTrue);
    expect(await tracker.hasChanged('a', key: 'k'), isFalse);
  });

  test('the store is capped, oldest first', () async {
    final t = ContentHashTracker(
      readFile: (path) async => utf8.encode(path),
      maxEntries: 2,
    );
    await t.hasChanged('a');
    await t.hasChanged('b');
    await t.hasChanged('c');
    expect(await t.hasChanged('b'), isFalse);
    expect(await t.hasChanged('a'), isTrue);
  });
}
