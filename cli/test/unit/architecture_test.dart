import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Enforces the module rules: `common/` imports no sibling, feature modules
/// import only `common/` and themselves, and nothing imports `cli/`.
void main() {
  final libSrc = p.join(Directory.current.path, 'lib', 'src');
  const featureModules = [
    'dap',
    'control',
    'sdk',
    'devices',
    'watch',
    'devtools',
    'init',
  ];

  final importPattern = RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''');

  /// The module (first folder under lib/src) a file or import points into,
  /// or null when it is outside lib/src.
  String? moduleOf(String path) {
    final rel = p.relative(path, from: libSrc);
    if (rel.startsWith('..')) return null;
    final parts = p.split(rel);
    return parts.length > 1 ? parts.first : null;
  }

  List<String> violationsFor(String module, bool Function(String) allowed) {
    final dir = Directory(p.join(libSrc, module));
    expect(dir.existsSync(), isTrue, reason: 'lib/src/$module must exist');
    final violations = <String>[];
    for (final file in dir.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final uri = importPattern.firstMatch(lines[i])?.group(1);
        if (uri == null || uri.startsWith('dart:')) continue;
        String? target;
        if (uri.startsWith('package:flutter_run/src/')) {
          target = moduleOf(
            p.join(libSrc, uri.substring('package:flutter_run/src/'.length)),
          );
        } else if (uri.startsWith('package:')) {
          continue;
        } else {
          target = moduleOf(p.normalize(p.join(p.dirname(file.path), uri)));
        }
        if (target == null || target == module) continue;
        if (!allowed(target)) {
          violations.add(
            '${p.relative(file.path, from: Directory.current.path)}:${i + 1} '
            'imports "$uri" (module $target)',
          );
        }
      }
    }
    return violations;
  }

  test('common imports no sibling module', () {
    final v = violationsFor('common', (_) => false);
    expect(v, isEmpty, reason: 'common/ must not depend on:\n${v.join('\n')}');
  });

  for (final module in featureModules) {
    test('$module imports only common', () {
      final v = violationsFor(module, (t) => t == 'common');
      expect(
        v,
        isEmpty,
        reason: '$module/ may only import common/:\n${v.join('\n')}',
      );
    });
  }

  test('nothing outside cli imports cli', () {
    final v = <String>[];
    for (final module in [...featureModules, 'common']) {
      v.addAll(violationsFor(module, (t) => t != 'cli'));
    }
    expect(v.where((e) => e.contains('(module cli)')), isEmpty);
  });
}
