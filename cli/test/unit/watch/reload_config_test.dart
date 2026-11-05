import 'package:flutter_run/src/watch/reload_config.dart';
import 'package:test/test.dart';

void main() {
  ReloadOnSaveConfig parse(Object? mode, {Object? globs, Object? debounce}) =>
      ReloadOnSaveConfig.fromOwnConfig({
        'reloadOnSave': ?mode,
        'reloadOnSaveGlobs': ?globs,
        'reloadOnSaveDebounceMs': ?debounce,
      });

  test('defaults', () {
    final c = ReloadOnSaveConfig.fromOwnConfig({});
    expect(c.mode, ReloadOnSaveMode.changed);
    expect(c.globs, isEmpty);
    expect(c.debounce, const Duration(milliseconds: 200));
    expect(c.warnings, isEmpty);
  });

  group('mode', () {
    final table = <Object, ReloadOnSaveMode>{
      true: ReloadOnSaveMode.changed,
      false: ReloadOnSaveMode.off,
      'changed': ReloadOnSaveMode.changed,
      'always': ReloadOnSaveMode.always,
      'off': ReloadOnSaveMode.off,
      'ALWAYS': ReloadOnSaveMode.always,
      ' Off ': ReloadOnSaveMode.off,
      'true': ReloadOnSaveMode.changed,
      'false': ReloadOnSaveMode.off,
    };
    table.forEach((input, expected) {
      test('$input -> $expected', () {
        final c = parse(input);
        expect(c.mode, expected);
        expect(c.warnings, isEmpty);
      });
    });

    for (final bad in <Object>['sometimes', 3, <Object>[]]) {
      test('$bad -> changed with a warning', () {
        final c = parse(bad);
        expect(c.mode, ReloadOnSaveMode.changed);
        expect(c.warnings.single, startsWith('Warning:'));
      });
    }
  });

  group('debounce', () {
    final table = <Object, int>{
      200: 200,
      1: 10,
      0: 10,
      -50: 10,
      99999: 5000,
      350.6: 351,
      '400': 400,
      '1': 10,
    };
    table.forEach((input, expected) {
      test('$input -> $expected ms', () {
        final c = parse(null, debounce: input);
        expect(c.debounce, Duration(milliseconds: expected));
        expect(c.warnings, isEmpty);
      });
    });

    for (final bad in <Object>['fast', true, <Object>[]]) {
      test('$bad -> default with a warning', () {
        final c = parse(null, debounce: bad);
        expect(c.debounce, const Duration(milliseconds: 200));
        expect(c.warnings, hasLength(1));
      });
    }
  });

  group('globs', () {
    test('valid strings are kept (trimmed)', () {
      final c = parse(null, globs: [' assets/**.json ', 'lib/**.arb']);
      expect(c.globs, ['assets/**.json', 'lib/**.arb']);
      expect(c.warnings, isEmpty);
    });
    test('bad entries are dropped with a warning', () {
      final c = parse(null, globs: ['a/*.x', 3, '']);
      expect(c.globs, ['a/*.x']);
      expect(c.warnings, hasLength(2));
    });
    test('non-list is ignored with a warning', () {
      final c = parse(null, globs: 'assets/**');
      expect(c.globs, isEmpty);
      expect(c.warnings, hasLength(1));
    });
  });
}
