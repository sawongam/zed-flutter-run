import 'dart:io';

import 'package:flutter_run/src/common/version.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('packageVersion equals pubspec.yaml version', () {
    final yaml = loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
    expect(packageVersion, yaml['version']);
    expect(yaml['name'], toolName);
  });

  test('constants', () {
    expect(adapterName, 'FlutterRun');
    expect(stateDirEnv, '${envPrefix}STATE_DIR');
    expect(controlProtocolVersion, 1);
    expect(sessionFileVersion, 1);
  });
}
