import 'dart:convert';
import 'dart:io';

import 'package:flutter_run/src/dap/launch_rewriter.dart';
import 'package:flutter_run/src/init/project_detect.dart';
import 'package:flutter_run/src/init/templates.dart';
import 'package:json_schema/json_schema.dart';
import 'package:test/test.dart';

File _schemaFile() {
  var dir = Directory.current;
  for (var i = 0; i < 4; i++) {
    final file = File(
      '${dir.path}/extension/debug_adapter_schemas/FlutterRun.json',
    );
    if (file.existsSync()) return file;
    dir = dir.parent;
  }
  throw StateError('FlutterRun.json not found above ${Directory.current.path}.');
}

const _flutter = ProjectInfo(
  root: '/p',
  name: 'app',
  kind: ProjectKind.flutter,
  usesFvm: false,
  dartEntry: 'lib/main.dart',
);
const _dart = ProjectInfo(
  root: '/p',
  name: 'tool',
  kind: ProjectKind.dart,
  usesFvm: false,
  dartEntry: 'bin/tool.dart',
);

void main() {
  late Map<String, Object?> raw;
  late JsonSchema schema;

  setUpAll(() {
    raw = jsonDecode(_schemaFile().readAsStringSync()) as Map<String, Object?>;
    schema = JsonSchema.create(raw);
  });

  test('is a valid draft-07 schema for objects that allow extra keys', () {
    expect(raw[r'$schema'], 'http://json-schema.org/draft-07/schema#');
    expect(schema.schemaVersion, SchemaVersion.draft7);
    expect(raw['type'], 'object');
    expect(raw['additionalProperties'], isTrue);
  });

  test('declares adapter FlutterRun only', () {
    final adapter = raw['properties']! as Map<String, Object?>;
    expect((adapter['adapter']! as Map)['enum'], ['FlutterRun']);
  });

  group('scenarios written by init validate', () {
    for (final (name, project) in [('Flutter', _flutter), ('Dart', _dart)]) {
      test('$name project', () {
        final scenarios = debugScenarios(project);
        expect(scenarios, isNotEmpty);
        for (final scenario in scenarios) {
          final result = schema.validate(scenario);
          expect(
            result.isValid,
            isTrue,
            reason: '${scenario['label']}: ${result.errors}',
          );
        }
      });
    }
  });

  group('hand-written samples', () {
    bool valid(Object? instance) => schema.validate(instance).isValid;

    test('a full launch entry is valid', () {
      expect(
        valid({
          'label': 'Flutter: Debug',
          'adapter': 'FlutterRun',
          'request': 'launch',
          'type': 'flutter',
          'program': 'lib/main.dart',
          'cwd': r'$ZED_WORKTREE_ROOT',
          'args': ['--flag'],
          'toolArgs': ['--flavor', 'dev'],
          'env': {'A': 'b'},
          'flutterMode': 'profile',
          'deviceId': 'linux',
          'platform': 'web',
          'stopOnEntry': false,
          'noDebug': false,
          'useFvm': true,
          'flutterSdkPath': '/sdk',
          'reloadOnSave': 'always',
          'reloadOnSaveGlobs': ['assets/**.json'],
          'reloadOnSaveDebounceMs': 300,
          'openDevTools': 'inspector',
          'logFile': '/tmp/x.log',
        }),
        isTrue,
      );
    });

    test('an attach entry is valid', () {
      expect(
        valid({
          'adapter': 'FlutterRun',
          'request': 'attach',
          'vmServiceUri': 'http://127.0.0.1:1/abc=/',
        }),
        isTrue,
      );
    });

    test('an unknown extra key is valid', () {
      expect(valid({'adapter': 'FlutterRun', 'somethingNew': 1}), isTrue);
    });

    test('reloadOnSave "sometimes" is invalid', () {
      expect(valid({'reloadOnSave': 'sometimes'}), isFalse);
    });

    test('openDevTools "foo" is invalid', () {
      expect(valid({'openDevTools': 'foo'}), isFalse);
    });

    test('other wrong values are invalid', () {
      expect(valid({'adapter': 'Dart'}), isFalse);
      expect(valid({'request': 'run'}), isFalse);
      expect(valid({'type': 'rust'}), isFalse);
      expect(valid({'flutterMode': 'fast'}), isFalse);
      expect(valid({'reloadOnSaveDebounceMs': 5}), isFalse);
      expect(valid({'reloadOnSaveDebounceMs': 9000}), isFalse);
      expect(valid({'toolArgs': 'x'}), isFalse);
      expect(
        valid({
          'env': {'A': 1},
        }),
        isFalse,
      );
      expect(valid('not an object'), isFalse);
    });
  });

  test('every key the proxy interprets is declared in the schema', () {
    final properties = (raw['properties']! as Map<String, Object?>).keys
        .toSet();
    final missing = LaunchRewriter.ownKeys
        .where((k) => k != 'adapter' && k != 'label')
        .where((k) => !properties.contains(k));
    expect(missing, isEmpty);
    // adapter and label are declared too.
    expect(properties, containsAll(['adapter', 'label']));
    // The keys are the twelve of plan section 4.2.
    expect(LaunchRewriter.ownKeys, hasLength(12));
    expect(LaunchRewriter.ownKeys, containsAll(['flutterMode', 'platform']));
  });
}
